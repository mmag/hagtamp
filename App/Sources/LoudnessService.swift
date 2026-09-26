import AudioCore
import Foundation
import PlayerCore

/// The loudness of tracks, for normalization: read from their ReplayGain
/// tags or measured, in the background, and kept in loudness.json. Tracks
/// about to play go first; the local library and the Navidrome cache follow
/// at background priority, a couple of files at a time.
@MainActor
final class LoudnessService {
    /// A file to read and where its loudness goes: under `key`, with its
    /// album (named by its tags) grouped within `albumScope`, which keeps
    /// sources apart.
    struct Job {
        var key: String
        var file: URL
        var albumScope: String
        /// A local file's size and date: it is read again when they change.
        var size: Int64?
        var modified: Date?
    }

    private nonisolated static var indexFile: URL { Storage.supportDirectory.appendingPathComponent("loudness.json") }
    /// Saves one after another, the last one last.
    private static let writer = DispatchQueue(label: "app.hagtamp.loudness", qos: .utility)
    private static let concurrency = 2

    private var index = LoudnessIndex()
    /// The saved index is loaded in the background; reading starts after it.
    private var isLoaded = false
    /// Tracks about to play.
    private var soon: [Job] = []
    /// What each source (the library, the Navidrome cache) has left to read, last first.
    private var backlogs: [String: [Job]] = [:]
    private var running: Set<String> = []
    /// Files that couldn't be read: not tried again until the next launch.
    private var unreadable: Set<String> = []
    private var saveTask: Task<Void, Never>?

    /// Reading waits while normalization is off (the player says which).
    var isEnabled = false {
        didSet { if isEnabled { next() } }
    }
    /// A track's loudness became known.
    var onRead: (() -> Void)?
    /// Reading made progress (for the preferences).
    var onProgress: (() -> Void)?
    /// What the tracks read so far need, typically (for tracks not read yet).
    private(set) var typicalGain: Double?

    init() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let saved = (try? Data(contentsOf: Self.indexFile)).flatMap { try? JSONDecoder().decode(LoudnessIndex.self, from: $0) }
            await self?.loaded(saved ?? LoudnessIndex())
        }
    }

    private func loaded(_ saved: LoudnessIndex) {
        index = saved
        isLoaded = true
        typicalGain = index.typicalGain
        // What was asked for meanwhile, less what turns out to be known.
        soon = soon.filter(needsReading)
        backlogs = backlogs.mapValues { $0.filter(needsReading) }
        forgetDeletedFiles()
        next()
        onRead?()
        onProgress?()
    }

    /// Tracks known; tracks waiting to be read.
    var knownCount: Int { index.count }
    var pendingCount: Int { soon.count + running.count + backlogs.values.reduce(0) { $0 + $1.count } }

    /// Local files are keyed by their path; their albums are one lot, library or not.
    static func key(forFile url: URL) -> String { url.path }
    static let fileAlbumScope = "file"

    /// The loudness under `key`; for a local file, only while it is as it was read.
    func loudness(forKey key: String) -> Loudness? {
        guard let record = index[key] else { return nil }
        if record.size != nil {
            let file = Self.fileAttributes(URL(fileURLWithPath: key))
            guard record.matches(size: file.size, modified: file.modified) else { return nil }
        }
        return index.loudness(for: key)
    }

    /// A track about to play: read first, unless it is known.
    func readSoon(_ job: Job) {
        guard needsReading(job) else { return }
        soon.removeAll { $0.key == job.key }
        soon.append(job)
        next()
    }

    /// A local file about to play.
    func readSoon(file url: URL) {
        let attributes = Self.fileAttributes(url)
        readSoon(Job(key: Self.key(forFile: url), file: url, albumScope: Self.fileAlbumScope, size: attributes.size, modified: attributes.modified))
    }

    /// Everything `source` has (the rest of it is read in the background),
    /// replacing what it gave before.
    func setBacklog(_ jobs: [Job], for source: String) {
        // Sorted by path, so an album's tracks come together; taken from the end.
        backlogs[source] = jobs.filter(needsReading).sorted { $0.file.path > $1.file.path }
        next()
        onProgress?()
    }

    /// One more for `source`'s backlog, read before the rest of it.
    func readLater(_ job: Job, source: String) {
        guard needsReading(job) else { return }
        backlogs[source, default: []].append(job)
        next()
        onProgress?()
    }

    static func fileAttributes(_ url: URL) -> (size: Int64?, modified: Date?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (values?.fileSize.map(Int64.init), values?.contentModificationDate)
    }

    private func needsReading(_ job: Job) -> Bool {
        guard !unreadable.contains(job.key), !running.contains(job.key) else { return false }
        return index[job.key].map { !$0.matches(size: job.size, modified: job.modified) } ?? true
    }

    private func next() {
        guard isEnabled, isLoaded else { return }
        while running.count < Self.concurrency, let (job, urgent) = takeJob() {
            running.insert(job.key)
            Task.detached(priority: urgent ? .utility : .background) { [weak self] in
                let reading = LoudnessReading.read(job.file)
                await self?.finished(job, reading)
            }
        }
    }

    private func takeJob() -> (Job, urgent: Bool)? {
        while !soon.isEmpty {
            let job = soon.removeFirst()
            if needsReading(job) { return (job, true) }
        }
        for source in backlogs.keys.sorted() {
            while let job = backlogs[source]?.popLast() {
                if needsReading(job) { return (job, false) }
            }
            backlogs[source] = nil
        }
        return nil
    }

    private func finished(_ job: Job, _ reading: LoudnessReading?) {
        running.remove(job.key)
        if let reading {
            index[job.key] = LoudnessIndex.Record(
                tags: reading.tags, measured: reading.measured, album: reading.album.map { job.albumScope + "\u{1F}" + $0 },
                size: job.size, modified: job.modified)
            if typicalGain == nil { typicalGain = index.typicalGain }
            scheduleSave()
            onRead?()
        } else {
            unreadable.insert(job.key)
        }
        next()
        onProgress?()
    }

    // MARK: - Saving

    /// A few seconds after the latest change, in the background.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.typicalGain = self.index.typicalGain
            let index = self.index
            Self.writer.async { Self.write(index) }
        }
    }

    /// Now, waiting for the file to be written (on quit).
    func saveNow() {
        guard saveTask != nil, isLoaded else { return }
        saveTask?.cancel()
        saveTask = nil
        let index = self.index
        Self.writer.sync { Self.write(index) }
    }

    private nonisolated static func write(_ index: LoudnessIndex) {
        try? JSONEncoder().encode(index).write(to: indexFile, options: .atomic)
    }

    /// Local files that are gone leave the index; those in a folder that
    /// isn't there (a disk not mounted) stay.
    private func forgetDeletedFiles() {
        let paths = index.records.keys.filter { $0.hasPrefix("/") }
        guard !paths.isEmpty else { return }
        Task.detached(priority: .background) { [weak self] in
            let manager = FileManager.default
            let gone = Set(paths.filter { path in
                !manager.fileExists(atPath: path) && manager.fileExists(atPath: (path as NSString).deletingLastPathComponent)
            })
            guard !gone.isEmpty else { return }
            await self?.forget(gone)
        }
    }

    private func forget(_ keys: Set<String>) {
        index.removeAll { key, _ in keys.contains(key) }
        scheduleSave()
    }
}
