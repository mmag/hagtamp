import AVFAudio
import Foundation
import PlayerCore
@preconcurrency import SFBAudioEngine

public enum EngineState: Sendable {
    case stopped, playing, paused
}

/// Playback on SFBAudioEngine: gapless queue, Winamp's 10-band equalizer
/// with preamp, balance, volume, and a sample feed for the visualizer.
///
/// Graph: decoder source → equalizer → balance mixer → main mixer (volume) → output.
@MainActor
public final class AudioEngine {
    public enum Event: Sendable {
        /// The track now being heard changed (nil when playback ran out).
        case nowPlaying(URL?)
        case state(EngineState)
        case endOfAudio
        case error(String)
    }

    public var onEvent: ((Event) -> Void)?
    /// Post-equalizer, pre-volume samples, like Winamp's visualization data.
    public let samples = SampleBuffer()

    private let player = AudioPlayer()
    private let graph: ProcessingGraph

    public init() {
        graph = ProcessingGraph(samples: samples)
        graph.onEvent = { [weak self] event in
            Task { @MainActor in self?.onEvent?(event) }
        }
        player.delegate = graph
        let source = player.sourceNode
        let graph = self.graph
        player.modifyProcessingGraph { engine in
            graph.insert(into: engine, after: source)
        }
    }

    // MARK: - Transport

    /// Starts `url` now, dropping anything queued.
    public func play(_ url: URL) throws {
        try player.play(url)
    }

    /// Queues `url` to follow the current track without a gap.
    public func enqueue(_ url: URL) throws {
        try player.enqueue(url)
    }

    public func clearQueue() {
        player.clearQueue()
    }

    public func pause() { player.pause() }
    public func resume() { player.resume() }

    public func stop() {
        player.stop()
        samples.clear()
    }

    public var state: EngineState {
        player.isPlaying ? .playing : player.isPaused ? .paused : .stopped
    }

    /// The track being heard.
    public var nowPlayingURL: URL? { player.nowPlaying?.inputSource.url }

    /// Seconds into the current track.
    public var currentTime: Double? { player.currentTime }
    public var totalTime: Double? { player.totalTime }

    public func seek(to fraction: Double) {
        _ = player.seek(position: min(1, max(0, fraction)))
    }

    // MARK: - Volume, balance, equalizer

    /// 0...1 slider position. Loudness follows a squared curve so the slider
    /// feels even, like Winamp's DirectSound output.
    public var volume: Double = 1 {
        didSet { player.mainMixerNode.outputVolume = Float(volume * volume) }
    }

    /// -1 (left) ... 1 (right).
    public var balance: Double = 0 {
        didSet { graph.balance.pan = Float(min(1, max(-1, balance))) }
    }

    /// Applies slider positions (0...1, 0.5 = 0 dB); the preamp only applies with the EQ on.
    public func setEqualizer(enabled: Bool, preamp: Double, bands: [Double]) {
        let eq = graph.equalizer
        eq.bypass = !enabled
        eq.globalGain = Float(EqualizerPreset.decibels(preamp))
        for (band, position) in zip(eq.bands, bands) {
            band.gain = Float(EqualizerPreset.decibels(position))
        }
    }
}

/// Owns the inserted nodes and receives SFBAudioEngine's delegate calls,
/// which arrive on the player's own threads.
final class ProcessingGraph: NSObject, AudioPlayer.Delegate, @unchecked Sendable {
    let equalizer = AVAudioUnitEQ(numberOfBands: 10)
    let balance = AVAudioMixerNode()
    private let samples: SampleBuffer
    var onEvent: (@Sendable (AudioEngine.Event) -> Void)?

    init(samples: SampleBuffer) {
        self.samples = samples
        super.init()
        Self.configureBands(equalizer)
    }

    /// Winamp's bands as a graphic equalizer: peaking filters as wide as the
    /// spacing to their neighbours, shelves at the ends (Winamp's response
    /// curve stays flat beyond the outer bands).
    static func configureBands(_ eq: AVAudioUnitEQ) {
        let f = equalizerFrequencies
        for (i, band) in eq.bands.enumerated() {
            band.frequency = Float(f[i])
            band.gain = 0
            band.bypass = false
            if i == 0 {
                band.filterType = .lowShelf
            } else if i == f.count - 1 {
                band.filterType = .highShelf
            } else {
                band.filterType = .parametric
                band.bandwidth = Float(max(0.3, (log2(f[i + 1]) - log2(f[i - 1])) / 2))
            }
        }
    }

    func insert(into engine: AVAudioEngine, after source: AVAudioNode) {
        engine.attach(equalizer)
        engine.attach(balance)
        let format = source.outputFormat(forBus: 0)
        engine.disconnectNodeOutput(source)
        engine.connect(source, to: equalizer, format: format)
        connect(engine, format: format)
    }

    private func connect(_ engine: AVAudioEngine, format: AVAudioFormat) {
        engine.connect(equalizer, to: balance, format: format)
        engine.connect(balance, to: engine.mainMixerNode, format: format)
        balance.removeTap(onBus: 0)
        let samples = self.samples
        balance.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            samples.append(buffer)
        }
    }

    // MARK: - AudioPlayer.Delegate

    func audioPlayer(_ audioPlayer: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        connect(engine, format: format)
        return equalizer
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, nowPlayingChanged nowPlaying: (any PCMDecoding)?) {
        onEvent?(.nowPlaying(nowPlaying?.inputSource.url))
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        switch playbackState {
        case .playing: onEvent?(.state(.playing))
        case .paused: onEvent?(.state(.paused))
        default: onEvent?(.state(.stopped))
        }
    }

    func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        onEvent?(.endOfAudio)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: any Error) {
        onEvent?(.error(error.localizedDescription))
    }
}
