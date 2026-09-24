import AudioCore
import ClassicUI
import Foundation
import PlayerCore

/// Player state as the UI sees it, on top of the audio engine.
///
/// Transport follows Winamp: Play restarts the track (or resumes when
/// paused), Pause toggles, Next/Previous keep the current state. The next
/// track is queued ahead of time so playback is gapless.
@MainActor
final class PlayerModel {
    /// Called after any change; the UI re-renders.
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?

    let engine = AudioEngine()
    private(set) var tracks: [TrackInfo] = []
    private(set) var currentIndex = 0
    private(set) var status = PlaybackStatus.stopped
    /// Index queued in the engine to follow the current track.
    private var queuedIndex: Int?

    var volume: Double = 200.0 / 255.0 {
        didSet { engine.volume = volume; save(); changed() }
    }
    var balance = 0.0 {
        didSet { engine.balance = balance; save(); changed() }
    }
    var shuffle = false {
        didSet { requeue(); save(); changed() }
    }
    var repeatEnabled = false {
        didSet { requeue(); save(); changed() }
    }

    var equalizerEnabled = true { didSet { applyEqualizer() } }
    var equalizerAuto = false { didSet { save(); changed() } }
    var preamp = 0.5 { didSet { applyEqualizer() } }
    var bands = [Double](repeating: 0.5, count: 10) { didSet { applyEqualizer() } }
    private(set) var userPresets: [EqualizerPreset] = []

    init() {
        restore()
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.volume = volume
        engine.balance = balance
        applyEqualizer()
    }

    var currentTrack: TrackInfo? { tracks.indices.contains(currentIndex) ? tracks[currentIndex] : nil }

    /// Seconds into the current track (0 when stopped).
    var elapsed: Double { status == .stopped ? 0 : engine.currentTime ?? 0 }

    /// Length of the current track: the decoder's once playing, else the tags'.
    var duration: Double? { (status != .stopped ? engine.totalTime : nil) ?? currentTrack?.duration }

    var position: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(1, elapsed / duration)
    }

    // MARK: - Playlist

    /// Replaces the playlist (Winamp's "Play file") and optionally starts it.
    func load(_ urls: [URL], play: Bool) {
        tracks = urls.map(TrackInfo.init(url:))
        currentIndex = 0
        readInfo()
        if play { self.play(trackAt: 0) } else { stop() }
        changed()
    }

    func append(_ urls: [URL]) {
        let start = tracks.count
        tracks += urls.map(TrackInfo.init(url:))
        readInfo(from: start)
        requeue()
        changed()
    }

    /// Tags are read in the background; the list shows file names meanwhile.
    private func readInfo(from start: Int = 0) {
        let pending = tracks[start...].map(\.url)
        Task.detached(priority: .userInitiated) {
            for url in pending {
                let info = TrackInfo.read(from: url)
                await MainActor.run { [weak self] in self?.update(info) }
            }
        }
    }

    private func update(_ info: TrackInfo) {
        for i in tracks.indices where tracks[i].url == info.url && tracks[i].duration == nil {
            tracks[i] = info
        }
        changed()
    }

    // MARK: - Transport

    func play() {
        switch status {
        case .paused:
            engine.resume()
        case .playing, .stopped:
            play(trackAt: currentIndex)
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
        queuedIndex = nil
        status = .stopped
        changed()
    }

    func next() { step(by: 1) }
    func previous() { step(by: -1) }

    func play(trackAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        currentIndex = index
        do {
            try engine.play(tracks[index].url)
            status = .playing
            requeue()
        } catch {
            onError?("Can't play “\(tracks[index].url.lastPathComponent)”: \(error.localizedDescription)")
            status = .stopped
        }
        changed()
    }

    func seek(to fraction: Double) {
        guard status != .stopped else { return }
        engine.seek(to: fraction)
        changed()
    }

    private func step(by offset: Int) {
        guard !tracks.isEmpty else { return }
        let index = shuffle ? Int.random(in: tracks.indices) : (currentIndex + offset + tracks.count) % tracks.count
        if status == .stopped {
            currentIndex = index
            changed()
        } else {
            play(trackAt: index)
        }
    }

    /// The track that follows `index` when it ends, honouring shuffle and repeat.
    private func followingIndex(after index: Int) -> Int? {
        guard !tracks.isEmpty else { return nil }
        if shuffle { return Int.random(in: tracks.indices) }
        if index + 1 < tracks.count { return index + 1 }
        return repeatEnabled ? 0 : nil
    }

    /// Re-queues the follower of the current track (after the playlist or play order changed).
    private func requeue() {
        guard status != .stopped else { return }
        engine.clearQueue()
        queuedIndex = followingIndex(after: currentIndex)
        if let queuedIndex { try? engine.enqueue(tracks[queuedIndex].url) }
    }

    // MARK: - Engine events

    private func handle(_ event: AudioEngine.Event) {
        switch event {
        case .nowPlaying(let url?):
            // The queued track took over: find it (queued index first, URLs may repeat).
            if let queuedIndex, tracks.indices.contains(queuedIndex), tracks[queuedIndex].url == url {
                currentIndex = queuedIndex
            } else if currentTrack?.url != url, let index = tracks.firstIndex(where: { $0.url == url }) {
                currentIndex = index
            }
            if currentIndex == queuedIndex { requeue() }
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
            queuedIndex = nil
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
        save()
    }

    func deleteUserPreset(named name: String) {
        userPresets.removeAll { $0.name == name }
        save()
    }

    private func applyEqualizer() {
        engine.setEqualizer(enabled: equalizerEnabled, preamp: preamp, bands: bands)
        save()
        changed()
    }

    // MARK: - Persistence

    private struct Saved: Codable {
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

    private static let savedKey = "player"
    private var restoring = false

    private func save() {
        guard !restoring else { return }
        let saved = Saved(
            volume: volume, balance: balance, shuffle: shuffle, repeatEnabled: repeatEnabled,
            equalizerEnabled: equalizerEnabled, equalizerAuto: equalizerAuto, preamp: preamp, bands: bands,
            userPresets: userPresets)
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.savedKey)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedKey),
            let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return }
        restoring = true
        defer { restoring = false }
        volume = saved.volume
        balance = saved.balance
        shuffle = saved.shuffle
        repeatEnabled = saved.repeatEnabled
        equalizerEnabled = saved.equalizerEnabled
        equalizerAuto = saved.equalizerAuto
        preamp = saved.preamp
        if saved.bands.count == 10 { bands = saved.bands }
        userPresets = saved.userPresets
    }

    private func changed() {
        onChange?()
    }
}
