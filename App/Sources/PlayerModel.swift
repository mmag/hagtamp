import AudioCore
import ClassicUI
import Foundation
import PlayerCore

/// Turns playlist URLs that aren't local files (Navidrome songs, internet
/// radio) into something playable.
@MainActor
protocol RemoteTrackResolver: AnyObject {
    func handles(_ url: URL) -> Bool
    /// Endless streams (radio) aren't queued ahead: they'd never hand over.
    func isLive(_ url: URL) -> Bool
    /// A file already on disk, without waiting.
    func cachedFile(for url: URL) -> URL?
    /// The cached file, or a download that can start playing, once enough of
    /// it is there (`progress` reports 0...1 of that).
    func prepare(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> PlayableSource
}

extension RemoteTrackResolver {
    func isLive(_ url: URL) -> Bool { false }
}

/// Player state as the UI sees it, on top of the audio engine.
///
/// Transport follows Winamp: Play restarts the track (or resumes when
/// paused), Pause toggles, Next/Previous keep the current state, tracks that
/// fail to play are skipped. The next track is queued ahead of time so
/// playback is gapless.
@MainActor
final class PlayerModel {
    /// Called after any change; the UI re-renders.
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?

    let engine = AudioEngine()
    /// Provide sources for entries that aren't local files, first match wins.
    var resolvers: [RemoteTrackResolver] = []
    private(set) var playlist = Playlist()
    private(set) var status = PlaybackStatus.stopped
    /// Progress 0...1 while a remote track buffers before playing.
    private(set) var buffering: Double?
    /// Entry queued in the engine to follow the current track.
    private var queuedID: UUID?
    /// A live stream to start when the current track ends (it can't be queued).
    private var followingLiveID: UUID?
    /// The song a radio station says it is playing.
    private(set) var streamTitle: String?
    /// Cached files (complete or still downloading) standing in for remote entries.
    private var localFiles: [UUID: URL] = [:]
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?

    var volume: Double = 200.0 / 255.0 {
        didSet { engine.volume = volume; saveSettings(); changed() }
    }
    var balance = 0.0 {
        didSet { engine.balance = balance; saveSettings(); changed() }
    }
    var shuffle = false {
        didSet { requeue(); saveSettings(); changed() }
    }
    var repeatEnabled = false {
        didSet { requeue(); saveSettings(); changed() }
    }

    var equalizerEnabled = true { didSet { applyEqualizer() } }
    var equalizerAuto = false { didSet { saveSettings(); changed() } }
    var preamp = 0.5 { didSet { applyEqualizer() } }
    var bands = [Double](repeating: 0.5, count: 10) { didSet { applyEqualizer() } }
    private(set) var userPresets: [EqualizerPreset] = []

    init() {
        restoreSettings()
        restorePlaylist()
        restorePosition()
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.volume = volume
        engine.balance = balance
        applyEqualizer()
    }

    var currentIndex: Int? { playlist.currentIndex }
    var currentTrack: TrackInfo? { currentIndex.map { playlist[$0].info } }

    /// The file being heard; it keeps playing (and showing) even if removed from the list.
    private(set) var nowPlayingURL: URL?

    /// What the displays show: the track being heard, else the current entry.
    var displayedTrack: TrackInfo? {
        guard status != .stopped, let url = nowPlayingURL else { return currentTrack }
        if let streamTitle { return TrackInfo(url: url, title: streamTitle) }
        if let current = currentTrack, current.url == url { return current }
        return playlist.entries.first { $0.url == url }?.info ?? TrackInfo(url: url)
    }

    /// Seconds into the current track (0 when stopped).
    var elapsed: Double { status == .stopped || buffering != nil ? 0 : engine.currentTime ?? 0 }

    /// Length of the current track: the decoder's once playing, else the tags'.
    var duration: Double? { (status != .stopped && buffering == nil ? engine.totalTime : nil) ?? displayedTrack?.duration }

    var position: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(1, elapsed / duration)
    }

    // MARK: - Playlist

    /// Replaces the playlist (Winamp's "Play file", LIST > LOAD) and optionally starts it.
    func load(_ urls: [URL], play: Bool) {
        load(tracks: Self.tracks(from: urls), play: play)
    }

    /// `tagsKnown`: the tracks come with complete tags (from a library), nothing to read.
    func load(tracks: [TrackInfo], play: Bool, tagsKnown: Bool = false) {
        stop()
        playlist.removeAll()
        playlist.insert(tracks, infoLoaded: tagsKnown)
        playlist.setCurrent(playlist.isEmpty ? nil : 0)
        readTags()
        playlistChanged()
        if play { self.play(trackAt: 0) }
    }

    /// Adds files, folders and playlist files at `index` (the end when nil).
    func add(_ urls: [URL], at index: Int? = nil) {
        add(tracks: Self.tracks(from: urls), at: index)
    }

    /// Adds tracks (Winamp's "Enqueue") at `index` (the end when nil).
    func add(tracks: [TrackInfo], at index: Int? = nil, tagsKnown: Bool = false) {
        let range = playlist.insert(tracks, at: index, infoLoaded: tagsKnown)
        if currentIndex == nil, !range.isEmpty { playlist.setCurrent(range.lowerBound) }
        readTags()
        playlistChanged()
    }

    /// Edits the playlist in place (selection, order, removals) and keeps playback consistent.
    func editPlaylist(_ edit: (inout Playlist) -> Void) {
        edit(&playlist)
        playlistChanged()
    }

    /// Selection-only changes skip requeueing and saving.
    func changeSelection(_ edit: (inout Playlist) -> Void) {
        edit(&playlist)
        changed()
    }

    /// Playlist files contribute their entries; titles/lengths from them show until tags are read.
    static func tracks(from urls: [URL]) -> [TrackInfo] {
        urls.flatMap { url -> [TrackInfo] in
            if PlaylistFile.isPlaylist(url) { return (try? PlaylistFile.read(url)) ?? [] }
            return WindowManager.audioFiles(in: [url]).map { TrackInfo(url: $0) }
        }
    }

    /// Tags of local files are read in the background; the list shows names
    /// meanwhile. Remote entries already carry their tags.
    private func readTags() {
        for entry in playlist.entries where !entry.infoLoaded && !entry.url.isFileURL {
            playlist.update(entry.info)
        }
        let pending = playlist.entries.filter { !$0.infoLoaded }.map(\.info)
        guard !pending.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            for placeholder in pending {
                var info = TrackInfo.read(from: placeholder.url)
                // Keep what the playlist file knew if the file itself can't be read.
                if info.duration == nil { info.duration = placeholder.duration }
                if info.title == nil && info.artist == nil { info.title = placeholder.title }
                let result = info
                await MainActor.run { [weak self] in
                    self?.playlist.update(result)
                    self?.changed()
                }
            }
            await MainActor.run { [weak self] in self?.savePlaylist() }
        }
    }

    private func playlistChanged() {
        requeue()
        savePlaylist()
        changed()
    }

    // MARK: - Transport

    func play() {
        switch status {
        case .paused:
            engine.resume()
        case .playing, .stopped:
            // Winamp plays the selected entry when there is no current one.
            play(trackAt: currentIndex ?? playlist.selectedIndices.first ?? 0)
        }
    }

    func pause() {
        guard buffering == nil else { return stop() }
        switch status {
        case .playing: engine.pause()
        case .paused: engine.resume()
        case .stopped: break
        }
    }

    func stop() {
        loadTask?.cancel()
        prefetchTask?.cancel()
        buffering = nil
        engine.stop()
        queuedID = nil
        followingLiveID = nil
        streamTitle = nil
        status = .stopped
        forgetPosition()
        changed()
    }

    func next() { step(by: 1) }
    func previous() { step(by: -1) }

    /// Plays an entry. Remote entries (Navidrome) start once enough of them
    /// has downloaded, showing the buffering progress, and keep downloading
    /// into the cache as they play. Entries that fail are skipped, at most
    /// once around the list.
    func play(trackAt index: Int, attempts: Int = 0) {
        guard playlist.entries.indices.contains(index), attempts < playlist.count else {
            stop()
            return
        }
        loadTask?.cancel()
        playlist.setCurrent(index)
        let entry = playlist[index]
        guard let resolver = resolver(for: entry.url) else {
            start(entry, .file(entry.url), attempts: attempts)
            return
        }
        if let cached = resolver.cachedFile(for: entry.url) {
            start(entry, .file(cached), attempts: attempts)
            return
        }
        prefetchTask?.cancel()
        engine.stop()
        queuedID = nil
        buffering = 0
        nowPlayingURL = entry.url
        status = .playing
        changed()
        loadTask = Task { [weak self] in
            do {
                let source = try await resolver.prepare(entry.url) { [weak self] value in
                    guard let self, self.buffering != nil, self.playlist.currentID == entry.id else { return }
                    self.buffering = value
                    self.changed()
                }
                guard let self, !Task.isCancelled, self.buffering != nil, self.playlist.currentID == entry.id else {
                    source.discard()
                    return
                }
                self.start(entry, source, attempts: attempts)
            } catch {
                guard let self, !Task.isCancelled, self.playlist.currentID == entry.id else { return }
                self.buffering = nil
                self.failed(entry, index: index, attempts: attempts, error: error)
            }
        }
    }

    private func start(_ entry: PlaylistEntry, _ source: PlayableSource, attempts: Int) {
        buffering = nil
        streamTitle = nil
        let resume = resumeAt?.url == entry.url ? resumeAt : nil
        resumeAt = nil
        do {
            // Back where it was at the last quit, if the file can seek (a stream can't yet).
            if let resume, case .file(let file) = source, let duration = entry.info.duration, duration > 0 {
                try engine.play(file, from: resume.seconds / duration)
            } else {
                try engine.play(source)
            }
            localFiles[entry.id] = source.url
            nowPlayingURL = entry.url
            status = .playing
            // play(_:) already dropped the old queue; clearing it again could
            // remove the new track before the decoder has picked it up.
            requeue(clearingQueue: false)
            changed()
        } catch {
            source.discard()
            failed(entry, index: playlist.entries.firstIndex { $0.id == entry.id } ?? 0, attempts: attempts, error: error)
        }
    }

    private func resolver(for url: URL) -> RemoteTrackResolver? {
        resolvers.first { $0.handles(url) }
    }

    /// A station's new song title, shown while it plays.
    func streamTitleChanged(_ title: String, for url: URL) {
        guard nowPlayingURL == url, status != .stopped else { return }
        streamTitle = title
        changed()
    }

    private func failed(_ entry: PlaylistEntry, index: Int, attempts: Int, error: Error) {
        onError?("Can't play “\(entry.info.displayName)”: \(error.localizedDescription)")
        play(trackAt: (index + 1) % max(1, playlist.count), attempts: attempts + 1)
    }

    func seek(to fraction: Double) {
        guard status != .stopped, buffering == nil else { return }
        if !engine.seek(to: fraction) {
            // A stream can't seek; once its download is complete the cached file takes over.
            guard let index = currentIndex, resolver(for: playlist[index].url) != nil,
                let file = localFiles[playlist[index].id], FileManager.default.fileExists(atPath: file.path),
                (try? engine.play(file, from: fraction)) != nil
            else { return }
            requeue(clearingQueue: false)
        }
        changed()
    }

    private func step(by offset: Int) {
        guard !playlist.isEmpty else { return }
        let current = currentIndex ?? 0
        let index = shuffle ? Int.random(in: 0..<playlist.count) : (current + offset + playlist.count) % playlist.count
        if status == .stopped {
            playlist.setCurrent(index)
            changed()
        } else {
            play(trackAt: index)
        }
    }

    /// The entry that follows the current one when it ends, honouring shuffle and repeat.
    private func followingIndex() -> Int? {
        guard !playlist.isEmpty, let current = currentIndex else { return nil }
        if shuffle { return Int.random(in: 0..<playlist.count) }
        if current + 1 < playlist.count { return current + 1 }
        return repeatEnabled ? 0 : nil
    }

    /// Re-queues the follower of the current track (after the playlist or
    /// play order changed). Remote followers start downloading ahead of time.
    private func requeue(clearingQueue: Bool = true) {
        guard status != .stopped, buffering == nil else { return }
        if clearingQueue { engine.clearQueue() }
        prefetchTask?.cancel()
        followingLiveID = nil
        guard let next = followingIndex() else {
            queuedID = nil
            return
        }
        let entry = playlist[next]
        guard let resolver = resolver(for: entry.url) else {
            queuedID = entry.id
            try? engine.enqueue(entry.url)
            return
        }
        if resolver.isLive(entry.url) {
            queuedID = nil
            followingLiveID = entry.id
            return
        }
        queuedID = entry.id
        if let cached = resolver.cachedFile(for: entry.url) {
            localFiles[entry.id] = cached
            try? engine.enqueue(cached)
            return
        }
        prefetchTask = Task { [weak self] in
            guard let source = try? await resolver.prepare(entry.url, progress: { _ in }) else { return }
            guard let self, !Task.isCancelled, self.queuedID == entry.id else {
                source.discard()
                return
            }
            self.localFiles[entry.id] = source.url
            try? self.engine.enqueue(source)
        }
    }

    /// The entry behind a file the engine reports (queued one first: URLs may repeat).
    private func entryIndex(playing file: URL) -> Int? {
        func plays(_ id: UUID?, _ index: Int?) -> Bool {
            guard let id, let index else { return false }
            return (localFiles[id] ?? playlist[index].url) == file
        }
        let queuedIndex = queuedID.flatMap { id in playlist.entries.firstIndex { $0.id == id } }
        if plays(queuedID, queuedIndex) { return queuedIndex }
        if plays(playlist.currentID, currentIndex) { return currentIndex }
        return playlist.entries.firstIndex { (localFiles[$0.id] ?? $0.url) == file }
    }

    // MARK: - Position between launches

    private struct SavedPosition: Codable {
        var url: URL
        var seconds: Double
    }

    private static let resumeKey = "player.resumePosition"
    private static let positionKey = "player.position"

    /// Continue the current track from where it was at the last quit (Preferences).
    var resumesPosition = Storage.defaults.bool(forKey: PlayerModel.resumeKey) {
        didSet {
            Storage.defaults.set(resumesPosition, forKey: Self.resumeKey)
            if !resumesPosition { forgetPosition() }
        }
    }
    /// Where the current entry starts the next time it plays.
    private var resumeAt: SavedPosition?
    private var positionSavedAt = Date.distantPast

    /// Keeps the position of what is playing or paused: every few seconds
    /// (`force` on quit). Stopping forgets it.
    func savePosition(force: Bool = false) {
        guard resumesPosition, force || Date().timeIntervalSince(positionSavedAt) >= 5 else { return }
        positionSavedAt = Date()
        guard status != .stopped, buffering == nil, let url = nowPlayingURL else { return }
        Storage.defaults.set(try? JSONEncoder().encode(SavedPosition(url: url, seconds: elapsed)), forKey: Self.positionKey)
    }

    private func restorePosition() {
        guard resumesPosition, let data = Storage.defaults.data(forKey: Self.positionKey),
            let saved = try? JSONDecoder().decode(SavedPosition.self, from: data),
            let index = currentIndex, playlist[index].url == saved.url
        else { return }
        resumeAt = saved
    }

    private func forgetPosition() {
        resumeAt = nil
        Storage.defaults.removeObject(forKey: Self.positionKey)
    }

    /// Self test: what a relaunch does with the saved position.
    func relaunchForTesting() {
        engine.stop()
        status = .stopped
        restorePosition()
        changed()
    }

    // MARK: - Engine events

    /// Debug hook (self test).
    var onEngineEvent: ((AudioEngine.Event) -> Void)?

    private func handle(_ event: AudioEngine.Event) {
        onEngineEvent?(event)
        switch event {
        case .nowPlaying(let file?):
            if let index = entryIndex(playing: file) {
                let changedTrack = index != currentIndex || playlist[index].id == queuedID
                playlist.setCurrent(index)
                if nowPlayingURL != playlist[index].url { streamTitle = nil }
                nowPlayingURL = playlist[index].url
                if changedTrack { requeue() }
            } else {
                nowPlayingURL = file
            }
        case .nowPlaying(nil):
            break
        case .state(let state):
            switch state {
            case .playing: status = .playing
            case .paused: status = .paused
            case .stopped where buffering != nil: break  // waiting for a download, not stopped
            case .stopped: status = .stopped
            }
        case .endOfAudio:
            if let id = followingLiveID, let index = playlist.entries.firstIndex(where: { $0.id == id }) {
                play(trackAt: index)  // the station starts when the track before it ends
            } else if buffering == nil {
                status = .stopped
                queuedID = nil
                streamTitle = nil
            }
        case .error(let message):
            onError?(message)
        }
        changed()
    }

    // MARK: - Equalizer

    func apply(_ preset: EqualizerPreset) {
        bands = preset.bands
        preamp = preset.preamp
    }

    func saveUserPreset(named name: String) {
        userPresets.removeAll { $0.name == name }
        userPresets.append(EqualizerPreset(name: name, bands: bands, preamp: preamp))
        saveSettings()
    }

    func deleteUserPreset(named name: String) {
        userPresets.removeAll { $0.name == name }
        saveSettings()
    }

    private func applyEqualizer() {
        engine.setEqualizer(enabled: equalizerEnabled, preamp: preamp, bands: bands)
        saveSettings()
        changed()
    }

    // MARK: - Persistence

    private struct Settings: Codable {
        var volume: Double
        var balance: Double
        var shuffle: Bool
        var repeatEnabled: Bool
        var equalizerEnabled: Bool
        var equalizerAuto: Bool
        var preamp: Double
        var bands: [Double]
        var userPresets: [EqualizerPreset]
    }

    private static let settingsKey = "player"
    private static let currentIndexKey = "playlistCurrentIndex"
    private var restoring = false

    /// Winamp keeps its playlist in winamp.m3u8 between sessions; so do we.
    private static var playlistURL: URL {
        Storage.supportDirectory.appendingPathComponent("playlist.m3u8")
    }

    private func savePlaylist() {
        let url = Self.playlistURL
        let data = PlaylistFile.data(for: playlist.entries.map(\.info), format: .m3u8, base: url.deletingLastPathComponent())
        try? data.write(to: url, options: .atomic)
        Storage.defaults.set(currentIndex ?? -1, forKey: Self.currentIndexKey)
    }

    private func restorePlaylist() {
        guard let tracks = try? PlaylistFile.read(Self.playlistURL), !tracks.isEmpty else { return }
        playlist.insert(tracks)
        let index = Storage.defaults.integer(forKey: Self.currentIndexKey)
        playlist.setCurrent(index >= 0 && index < tracks.count ? index : 0)
        readTags()
    }

    private func saveSettings() {
        guard !restoring else { return }
        let settings = Settings(
            volume: volume, balance: balance, shuffle: shuffle, repeatEnabled: repeatEnabled,
            equalizerEnabled: equalizerEnabled, equalizerAuto: equalizerAuto, preamp: preamp, bands: bands,
            userPresets: userPresets)
        Storage.defaults.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
    }

    private func restoreSettings() {
        guard let data = Storage.defaults.data(forKey: Self.settingsKey),
            let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return }
        restoring = true
        defer { restoring = false }
        volume = settings.volume
        balance = settings.balance
        shuffle = settings.shuffle
        repeatEnabled = settings.repeatEnabled
        equalizerEnabled = settings.equalizerEnabled
        equalizerAuto = settings.equalizerAuto
        preamp = settings.preamp
        if settings.bands.count == 10 { bands = settings.bands }
        userPresets = settings.userPresets
    }

    private func changed() {
        onChange?()
    }
}
