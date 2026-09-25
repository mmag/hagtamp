import Foundation
@preconcurrency import SFBAudioEngine

/// Tag reading progress of a scan.
public struct ScanProgress: Sendable, Equatable {
    public var read: Int
    public var total: Int
}

/// The local library: audio files under the chosen folders, indexed with
/// their tags and kept in a file between launches. Rescans read the tags of
/// new and changed files only.
public actor LocalLibrary {
    private let indexFile: URL
    private var folders: [URL] = []
    /// By path.
    private var entries: [String: LibraryEntry] = [:]
    public private(set) var catalog = LibraryCatalog()
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var onCatalog: (@Sendable (LibraryCatalog) -> Void)?
    private var onProgress: (@Sendable (ScanProgress?) -> Void)?
    /// Called when a file's tags are read (tests count rereads).
    private var onRead: (@Sendable (URL) -> Void)?

    func observeReads(_ observer: @escaping @Sendable (URL) -> Void) {
        onRead = observer
    }

    public init(indexFile: URL) {
        self.indexFile = indexFile
    }

    /// `catalog` gets every new catalog; `progress` the scan's progress, nil when it ends.
    public func observe(
        catalog: @escaping @Sendable (LibraryCatalog) -> Void, progress: @escaping @Sendable (ScanProgress?) -> Void
    ) {
        onCatalog = catalog
        onProgress = progress
    }

    /// Loads the saved index, then rescans `folders`.
    public func open(folders: [URL]) {
        self.folders = folders
        if let data = try? Data(contentsOf: indexFile), let index = try? JSONDecoder().decode(Index.self, from: data) {
            entries = Dictionary(index.entries.map { ($0.url.path, $0) }) { first, _ in first }
            entries = entries.filter { Self.isInside($0.value.url, folders) }
            publish()
        }
        rescan()
    }

    /// Changes the folders: files outside them leave the library at once, new ones arrive with the scan.
    public func setFolders(_ folders: [URL]) {
        self.folders = folders
        let before = entries.count
        entries = entries.filter { Self.isInside($0.value.url, folders) }
        if entries.count != before {
            publish()
            save()
        }
        rescan()
    }

    /// Picks up added, changed and removed files.
    public func rescan() {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        scanTask = Task { await scan(generation) }
    }

    /// Waits for the running scan (tests).
    public func waitForScan() async {
        await scanTask?.value
    }

    public var isEmpty: Bool { entries.isEmpty }

    // MARK: - Scanning

    struct FoundFile: Sendable {
        var url: URL
        var size: Int64
        var modified: Date
        var created: Date
    }

    private func scan(_ generation: Int) async {
        let folders = self.folders
        let extensions = AudioDecoder.supportedPathExtensions
        let found = await Task.detached(priority: .utility) { Self.audioFiles(in: folders, extensions: extensions) }.value
        guard generation == scanGeneration else { return }

        // Files that are gone leave now; changed ones keep their old tags until reread.
        // A folder that isn't there at all (a disk not mounted) keeps its files.
        let foundPaths = Set(found.map(\.url.path))
        let unreachable = folders.filter { !FileManager.default.fileExists(atPath: $0.path) }
        func stays(_ entry: (key: String, value: LibraryEntry)) -> Bool {
            foundPaths.contains(entry.key) || (!unreachable.isEmpty && Self.isInside(entry.value.url, unreachable))
        }
        let removed = entries.contains { !stays($0) }
        entries = entries.filter(stays)
        let firstImport = entries.isEmpty
        let toRead: [(file: FoundFile, added: Date)] = found.compactMap { file in
            let old = entries[file.url.path]
            // The index keeps dates to about a microsecond.
            if let old, old.fileSize == file.size, abs(old.modified.timeIntervalSince(file.modified)) < 0.001 { return nil }
            return (file, old?.added ?? min(file.created, Date()))
        }
        if removed { publish() }

        if !toRead.isEmpty { onProgress?(ScanProgress(read: 0, total: toRead.count)) }
        var done = 0
        var lastPublish = Date()
        let onRead = self.onRead
        for start in stride(from: 0, to: toRead.count, by: 32) {
            let batch = Array(toRead[start..<min(start + 32, toRead.count)])
            let read = await withTaskGroup(of: LibraryEntry.self) { group in
                for (file, added) in batch {
                    group.addTask(priority: .utility) {
                        onRead?(file.url)
                        return LibraryEntry.read(file.url, fileSize: file.size, modified: file.modified, added: added)
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            guard generation == scanGeneration, !Task.isCancelled else { return }
            for entry in read { entries[entry.url.path] = entry }
            done += read.count
            onProgress?(ScanProgress(read: done, total: toRead.count))
            // A first import shows the library growing; later scans change it once, at the end.
            if firstImport, Date().timeIntervalSince(lastPublish) > 2 {
                publish()
                lastPublish = Date()
            }
        }
        if !toRead.isEmpty || removed {
            publish()
            save()
        }
        onProgress?(nil)
    }

    static func audioFiles(in folders: [URL], extensions: Set<String>) -> [FoundFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        var found: [String: FoundFile] = [:]
        for folder in folders {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in enumerator where extensions.contains(url.pathExtension.lowercased()) {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                found[url.path] = FoundFile(
                    url: url, size: Int64(values.fileSize ?? 0), modified: modified, created: values.creationDate ?? modified)
            }
        }
        return Array(found.values)
    }

    /// The enumerator may report files with symlinks resolved (/var is /private/var).
    static func isInside(_ url: URL, _ folders: [URL]) -> Bool {
        folders.contains { folder in
            [folder.path, resolved(folder.path)].contains { url.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
    }

    /// A path with symlinks resolved, also for a folder that isn't there
    /// (its nearest existing parent is resolved).
    static func resolved(_ path: String) -> String {
        var head = path, tail: [String] = []
        while !head.isEmpty, head != "/" {
            if let pointer = realpath(head, nil) {
                defer { free(pointer) }
                return ([String(cString: pointer)] + tail).joined(separator: "/")
            }
            tail.insert((head as NSString).lastPathComponent, at: 0)
            head = (head as NSString).deletingLastPathComponent
        }
        return path
    }

    // MARK: - Index

    private struct Index: Codable {
        var version = 1
        var entries: [LibraryEntry]
    }

    private func publish() {
        catalog = LibraryCatalog(entries.values)
        onCatalog?(catalog)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: indexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Index(entries: Array(entries.values))) else { return }
        try? data.write(to: indexFile, options: .atomic)
    }
}
