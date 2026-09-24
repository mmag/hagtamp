import ClassicUI
import Foundation

/// Player state as the UI sees it.
///
/// Stage 2 stand-in: playback is simulated with a timer over a fixed demo
/// playlist so every display can be exercised. The audio engine replaces the
/// simulation in stage 3; the interface stays.
@MainActor
final class PlayerModel {
    struct Track {
        var artist: String
        var title: String
        var duration: Int
        var kbps = 128
        var khz = 44
        var channels = 2

        var displayName: String { "\(artist) - \(title)" }
    }

    /// Called after any change; the UI re-renders.
    var onChange: (() -> Void)?

    private(set) var tracks: [Track] = ReferenceScene.tracks.map { Track(artist: $0.artist, title: $0.title, duration: $0.seconds) }
    private(set) var currentIndex = 0
    private(set) var status = PlaybackStatus.stopped
    private(set) var elapsed = 0.0

    var volume = 200.0 / 255.0 { didSet { changed() } }
    var balance = 0.0 { didSet { changed() } }
    var shuffle = false { didSet { changed() } }
    var repeatEnabled = false { didSet { changed() } }

    var equalizerEnabled = true { didSet { changed() } }
    var equalizerAuto = false { didSet { changed() } }
    var preamp = 0.5 { didSet { changed() } }
    var bands = [Double](repeating: 0.5, count: 10) { didSet { changed() } }

    private var timer: Timer?
    private var lastTick = Date()

    var currentTrack: Track? { tracks.indices.contains(currentIndex) ? tracks[currentIndex] : nil }

    var position: Double {
        guard let track = currentTrack, track.duration > 0 else { return 0 }
        return min(1, elapsed / Double(track.duration))
    }

    // MARK: - Transport (Winamp semantics)

    /// Play restarts the current track when playing, resumes when paused.
    func play() {
        switch status {
        case .paused:
            status = .playing
        case .playing, .stopped:
            elapsed = 0
            status = .playing
        }
        startClock()
        changed()
    }

    /// Pause toggles between paused and playing; it does nothing when stopped.
    func pause() {
        switch status {
        case .playing: status = .paused
        case .paused: status = .playing
        case .stopped: return
        }
        startClock()
        changed()
    }

    func stop() {
        status = .stopped
        elapsed = 0
        stopClock()
        changed()
    }

    func next() { advance(by: 1, wrap: true) }
    func previous() { advance(by: -1, wrap: true) }

    func play(trackAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        currentIndex = index
        elapsed = 0
        status = .playing
        startClock()
        changed()
    }

    func seek(to fraction: Double) {
        guard status != .stopped, let track = currentTrack else { return }
        elapsed = min(1, max(0, fraction)) * Double(track.duration)
        changed()
    }

    private func advance(by step: Int, wrap: Bool) {
        guard !tracks.isEmpty else { return }
        var index = shuffle ? Int.random(in: tracks.indices) : currentIndex + step
        if index >= tracks.count || index < 0 {
            guard wrap else { stop(); return }
            index = (index + tracks.count) % tracks.count
        }
        currentIndex = index
        elapsed = 0
        changed()
    }

    // MARK: - Simulated clock

    private func startClock() {
        guard timer == nil else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopClock() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        defer { lastTick = now }
        guard status == .playing, let track = currentTrack else { return }
        elapsed += now.timeIntervalSince(lastTick)
        if elapsed >= Double(track.duration) {
            // End of track: continue with the next one; stop after the last unless repeating.
            if currentIndex == tracks.count - 1 && !repeatEnabled && !shuffle {
                stop()
                return
            }
            advance(by: 1, wrap: true)
        }
        changed()
    }

    private func changed() {
        onChange?()
    }
}
