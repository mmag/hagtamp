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
    /// Tags of an entry restored from the saved playlist, which keeps only
    /// "Artist - Title" and the length (nil: that is all there is).
    func info(for url: URL) async -> TrackInfo?
    /// Where an entry's loudness is kept (nil: it is never measured, like radio).
    func loudnessKey(for url: URL) -> String?
    /// Reading the loudness of an entry's downloaded file (nil: not downloaded).
    func loudnessJob(for url: URL) -> LoudnessService.Job?
}

extension RemoteTrackResolver {
    func isLive(_ url: URL) -> Bool { false }
    func info(for url: URL) async -> TrackInfo? { nil }
    func loudnessKey(for url: URL) -> String? { nil }
    func loudnessJob(for url: URL) -> LoudnessService.Job? { nil }
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
    let loudness: LoudnessService
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
    /// Moving on from an entry that failed; Stop or another start calls it off.
    private var skipTask: Task<Void, Never>?
    /// Normalization gains of the entries handed to the engine, oldest
    /// first: the one playing and the one queued after it.
    private var gains: [(id: UUID, gain: TrackGain)] = []

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

    /// Loudness normalization (Preferences).
    var normalization = Normalization() {
        didSet {
            loudness.isEnabled = normalization.enabled
            updateGains(includingStarted: true)
            saveSettings()
            changed()
        }
    }

    var equalizerEnabled = true { didSet { applyEqualizer() } }
    var equalizerAuto = false { didSet { saveSettings(); changed() } }
    var preamp = 0.5 { didSet { applyEqualizer() } }
    var bands = [Double](repeating: 0.5, count: 10) { didSet { applyEqualizer() } }
    private(set) var userPresets: [EqualizerPreset] = []

    init(loudness: LoudnessService) {
        self.loudness = loudness
        restoreSettings()
        restorePlaylist()
        restorePosition()
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.volume = volume
        engine.balance = balance
        applyEqualizer()
        loudness.isEnabled = normalization.enabled
        loudness.onRead = { [weak self] in self?.updateGains(includingStarted: false) }
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
        setCurrent(playlist.isEmpty ? nil : 0)
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
        if currentIndex == nil, !range.isEmpty { setCurrent(range.lowerBound) }
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
    /// meanwhile. Remote entries carry theirs, except when restored from the
    /// saved playlist: their resolver looks them up.
    private func readTags() {
        var remote: [(RemoteTrackResolver, TrackInfo)] = []
        for entry in playlist.entries where !entry.infoLoaded && !entry.url.isFileURL {
            if let resolver = resolver(for: entry.url) { remote.append((resolver, entry.info)) }
            playlist.update(entry.info)
        }
        if !remote.isEmpty {
            Task { [weak self] in
                for (resolver, placeholder) in remote {
                    guard var info = await resolver.info(for: placeholder.url) else { continue }
                    if info.duration == nil { info.duration = placeholder.duration }
                    self?.playlist.update(info)
                    self?.changed()
                }
            }
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
        skipTask?.cancel()
        if fadeTask != nil { cancelFade() }
        stopsAfterCurrent = false
        loadTask?.cancel()
        prefetchTask?.cancel()
        buffering = nil
        engine.stop()
        gains = []
        queuedID = nil
        followingLiveID = nil
        streamTitle = nil
        status = .stopped
        forgetPosition()
        changed()
    }

    func next() { step(by: 1) }
    func previous() { step(by: -1) }

    /// Winamp's "10 tracks fwd/back" (numeric keypad 3 and 1).
    func skip(tracks: Int) {
        guard !playlist.isEmpty else { return }
        let index = min(max(0, (currentIndex ?? 0) + tracks), playlist.count - 1)
        if status == .stopped {
            setCurrent(index)
            changed()
        } else {
            play(trackAt: index)
        }
    }

    /// Winamp's "Start of list" (Ctrl+Z).
    func startOfList() {
        guard !playlist.isEmpty else { return }
        if status == .stopped {
            setCurrent(0)
            changed()
        } else {
            play(trackAt: 0)
        }
    }

    /// Plays on to the end of the current track, then stops (Ctrl+V).
    var stopsAfterCurrent = false {
        didSet {
            requeue()
            changed()
        }
    }

    private var fadeTask: Task<Void, Never>?

    /// Winamp's "Stop w/ fadeout" (Shift+V): the volume falls over a second and a half.
    func fadeOutAndStop() {
        guard status == .playing, fadeTask == nil else { return stop() }
        let start = volume
        fadeTask = Task { [weak self] in
            for step in 1...30 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                self.engine.volume = start * (1 - Double(step) / 30)
            }
            guard let self, !Task.isCancelled else { return }
            self.stop()  // restores the volume for the next Play
        }
    }

    private func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
        engine.volume = volume
    }

    /// Plays an entry. Remote entries (Navidrome) start once enough of them
    /// has downloaded, showing the buffering progress, and keep downloading
    /// into the cache as they play. Entries that fail are skipped, at most
    /// once around the list.
    func play(trackAt index: Int, attempts: Int = 0) {
        skipTask?.cancel()
        if fadeTask != nil { cancelFade() }
        guard playlist.entries.indices.contains(index), attempts < playlist.count else {
            stop()
            return
        }
        loadTask?.cancel()
        setCurrent(index)
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
        gains = []
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
        startingID = entry.id
        do {
            let gain = self.gain(for: entry)
            // Back where it was at the last quit, if the file can seek (a stream can't yet).
            if let resume, case .file(let file) = source, let duration = entry.info.duration, duration > 0 {
                gains = [(entry.id, try engine.play(file, from: resume.seconds / duration, gain: gain))]
            } else {
                gains = [(entry.id, try engine.play(source, gain: gain))]
            }
            readLoudness(entry, source)
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

    /// Skips to the next entry, a moment later: a run of unplayable entries
    /// is walked one by one rather than recursively.
    private func failed(_ entry: PlaylistEntry, index: Int, attempts: Int, error: Error) {
        onError?("Can't play \(entry.info.displayName)")  // the marquee has room for little more
        let next = (index + 1) % max(1, playlist.count)
        skipTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            self?.play(trackAt: next, attempts: attempts + 1)
        }
    }

    func seek(to fraction: Double) {
        guard status != .stopped, buffering == nil else { return }
        if !engine.seek(to: fraction) {
            // A stream can't seek; once its download is complete the cached file takes over.
            guard let index = currentIndex, resolver(for: playlist[index].url) != nil,
                let file = resolver(for: playlist[index].url)?.cachedFile(for: playlist[index].url)
            else { return }
            let entry = playlist[index]
            startingID = entry.id
            guard let handle = try? engine.play(file, from: fraction, gain: gain(for: entry)) else { return }
            gains = [(entry.id, handle)]
            requeue(clearingQueue: false)
        }
        changed()
    }

    private func step(by offset: Int) {
        guard !playlist.isEmpty else { return }
        let current = currentIndex ?? 0
        let index = shuffle ? Int.random(in: 0..<playlist.count) : (current + offset + playlist.count) % playlist.count
        if status == .stopped {
            setCurrent(index)
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
        if clearingQueue {
            engine.clearQueue()
            // The track playing stays, and a queued one the player has begun decoding still plays.
            gains = gains.prefix(1) + gains.dropFirst().filter { $0.gain.hasStarted }
        }
        prefetchTask?.cancel()
        followingLiveID = nil
        guard !stopsAfterCurrent, let next = followingIndex() else {
            queuedID = nil
            return
        }
        let entry = playlist[next]
        guard let resolver = resolver(for: entry.url) else {
            queuedID = entry.id
            enqueue(entry, .file(entry.url))
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
            enqueue(entry, .file(cached))
            return
        }
        prefetchTask = Task { [weak self] in
            guard let source = try? await resolver.prepare(entry.url, progress: { _ in }) else { return }
            guard let self, !Task.isCancelled, self.queuedID == entry.id else {
                source.discard()
                return
            }
            self.localFiles[entry.id] = source.url
            self.enqueue(entry, source)
        }
    }

    private func enqueue(_ entry: PlaylistEntry, _ source: PlayableSource) {
        guard let handle = try? engine.enqueue(source, gain: gain(for: entry)) else { return }
        gains.append((entry.id, handle))
        readLoudness(entry, source)
    }

    /// The entry just handed to the engine by play(): the next "now playing"
    /// for its file is its start, even if the same file is queued after it.
    private var startingID: UUID?

    /// The entry behind a file the engine reports (queued one first: URLs may repeat).
    private func entryIndex(playing file: URL) -> Int? {
        func plays(_ id: UUID?, _ index: Int?) -> Bool {
            guard let id, let index else { return false }
            return (localFiles[id] ?? playlist[index].url) == file
        }
        if let id = startingID, let index = playlist.entries.firstIndex(where: { $0.id == id }), plays(id, index) {
            startingID = nil
            return index
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
        gains = []
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
                // Tracks before this one are done (it may follow itself, on repeat).
                if changedTrack, let playing = gains.lastIndex(where: { $0.id == playlist[index].id && $0.gain.hasStarted }) {
                    gains.removeFirst(playing)
                }
                setCurrent(index)
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
            // A station can't be queued, and a download may not have been ready in
            // time: either starts now that the track before it has ended.
            if let id = followingLiveID ?? queuedID, let index = playlist.entries.firstIndex(where: { $0.id == id }) {
                play(trackAt: index)
            } else if buffering == nil {
                // SFB leaves its engine running on silence (keeping the output
                // device busy) until told to stop.
                engine.stop()
                gains = []
                status = .stopped
                queuedID = nil
                streamTitle = nil
                forgetPosition()
                if stopsAfterCurrent { stopsAfterCurrent = false }
            }
        case .error(let message):
            onError?(message)
        }
        changed()
    }

    // MARK: - Loudness normalization

    /// Where an entry's loudness is kept: its file's path, or its server's song.
    private func loudnessKey(_ entry: PlaylistEntry) -> String? {
        entry.url.isFileURL ? LoudnessService.key(forFile: entry.url) : resolver(for: entry.url)?.loudnessKey(for: entry.url)
    }

    /// The gain for an entry, dB: from its tags or as measured, its album's
    /// while that album plays in order.
    private func gain(for entry: PlaylistEntry) -> Double {
        guard normalization.enabled else { return 0 }
        let known = entry.info.replayGain ?? loudnessKey(entry).flatMap(loudness.loudness(forKey:))
        let album = normalization.usesAlbumGain(shuffle: shuffle, continuesAlbum: continuesAlbum(entry))
        return normalization.gain(for: known, album: album, typicalGain: loudness.typicalGain)
    }

    /// Whether the entry before or after this one is from the same album.
    private func continuesAlbum(_ entry: PlaylistEntry) -> Bool {
        let entries = playlist.entries
        guard let album = entry.info.album?.lowercased(), !album.isEmpty, let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            return false
        }
        return [index - 1, index + 1].contains { entries.indices.contains($0) && entries[$0].info.album?.lowercased() == album }
    }

    /// Has an entry about to play read for its loudness, unless it is known;
    /// a download once it is complete.
    private func readLoudness(_ entry: PlaylistEntry, _ source: PlayableSource) {
        guard normalization.enabled else { return }
        guard let resolver = resolver(for: entry.url) else {
            loudness.readSoon(file: entry.url)
            return
        }
        switch source {
        case .file:
            if let job = resolver.loudnessJob(for: entry.url) { loudness.readSoon(job) }
        case .stream(let track):
            Task { [weak self, weak resolver] in
                guard await track.downloaded(), let job = resolver?.loudnessJob(for: entry.url) else { return }
                self?.loudness.readSoon(job)
            }
        case .live:
            break
        }
    }

    /// New gains for the tracks handed to the engine: all of them when the
    /// settings change (a playing track glides to its new level), only
    /// those not begun when a loudness becomes known (a track keeps its level).
    private func updateGains(includingStarted: Bool) {
        for (id, gain) in gains where includingStarted || !gain.hasStarted {
            guard let entry = playlist.entries.first(where: { $0.id == id }) else { continue }
            gain.decibels = self.gain(for: entry)
        }
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
        var normalization: Normalization?
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

    /// Makes an entry current and remembers it for the next launch (with the
    /// saved position, which only applies to the entry it was saved for).
    private func setCurrent(_ index: Int?) {
        playlist.setCurrent(index)
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
            userPresets: userPresets, normalization: normalization)
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
        if let saved = settings.normalization { normalization = saved }
    }

    private func changed() {
        onChange?()
    }
}
