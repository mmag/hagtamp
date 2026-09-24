import AudioCore
import ClassicUI
import Foundation
import PlayerCore

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
    private(set) var playlist = Playlist()
    private(set) var status = PlaybackStatus.stopped
    /// Entry queued in the engine to follow the current track.
    private var queuedID: UUID?

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
        if let current = currentTrack, current.url == url { return current }
        return playlist.entries.first { $0.url == url }?.info ?? TrackInfo(url: url)
    }

    /// Seconds into the current track (0 when stopped).
    var elapsed: Double { status == .stopped ? 0 : engine.currentTime ?? 0 }

    /// Length of the current track: the decoder's once playing, else the tags'.
    var duration: Double? { (status != .stopped ? engine.totalTime : nil) ?? displayedTrack?.duration }

    var position: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(1, elapsed / duration)
    }

    // MARK: - Playlist

    /// Replaces the playlist (Winamp's "Play file", LIST > LOAD) and optionally starts it.
    func load(_ urls: [URL], play: Bool) {
        stop()
        playlist.removeAll()
        playlist.insert(Self.tracks(from: urls))
        playlist.setCurrent(playlist.isEmpty ? nil : 0)
        readTags()
        playlistChanged()
        if play { self.play(trackAt: 0) }
    }

    /// Adds files, folders and playlist files at `index` (the end when nil).
    func add(_ urls: [URL], at index: Int? = nil) {
        let range = playlist.insert(Self.tracks(from: urls), at: index)
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

    /// Tags are read in the background; the list shows names meanwhile.
    private func readTags() {
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
        switch status {
        case .playing: engine.pause()
        case .paused: engine.resume()
        case .stopped: break
        }
    }

    func stop() {
        engine.stop()
        queuedID = nil
        status = .stopped
        changed()
    }

    func next() { step(by: 1) }
    func previous() { step(by: -1) }

    /// Plays an entry; entries that fail are skipped (at most once around the list).
    func play(trackAt index: Int, attempts: Int = 0) {
        guard playlist.entries.indices.contains(index), attempts < playlist.count else {
            stop()
            return
        }
        playlist.setCurrent(index)
        do {
            try engine.play(playlist[index].url)
            nowPlayingURL = playlist[index].url
            status = .playing
            requeue()
        } catch {
            onError?("Can't play “\(playlist[index].info.displayName)”: \(error.localizedDescription)")
            let next = (index + 1) % playlist.count
            play(trackAt: next, attempts: attempts + 1)
            return
        }
        changed()
    }

    func seek(to fraction: Double) {
        guard status != .stopped else { return }
        engine.seek(to: fraction)
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

    /// Re-queues the follower of the current track (after the playlist or play order changed).
    private func requeue() {
        guard status != .stopped else { return }
        engine.clearQueue()
        let next = followingIndex()
        queuedID = next.map { playlist[$0].id }
        if let next { try? engine.enqueue(playlist[next].url) }
    }

    // MARK: - Engine events

    private func handle(_ event: AudioEngine.Event) {
        switch event {
        case .nowPlaying(let url?):
            nowPlayingURL = url
            // The queued entry took over (URLs may repeat, so prefer it).
            if let queuedID, let index = playlist.entries.firstIndex(where: { $0.id == queuedID }), playlist[index].url == url {
                playlist.setCurrent(index)
                requeue()
            } else if currentTrack?.url != url, let index = playlist.entries.firstIndex(where: { $0.url == url }) {
                playlist.setCurrent(index)
                requeue()
            }
        case .nowPlaying(nil):
            break
        case .state(let state):
            switch state {
            case .playing: status = .playing
            case .paused: status = .paused
            case .stopped: status = .stopped
            }
        case .endOfAudio:
            status = .stopped
            queuedID = nil
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
