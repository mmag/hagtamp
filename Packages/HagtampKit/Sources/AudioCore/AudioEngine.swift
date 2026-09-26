import AVFAudio
import Foundation
import PlayerCore
@preconcurrency import SFBAudioEngine
import StreamingInput

public enum EngineState: Sendable {
    case stopped, playing, paused
}

/// Playback on SFBAudioEngine: gapless queue, Winamp's 10-band equalizer
/// with preamp, balance, volume, and a sample feed for the visualizer.
///
/// Graph: decoder source → equalizer → balance mixer → main mixer (volume) → output.
/// Each track's normalization gain is applied as it is decoded (`GainDecoder`).
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
    /// Decoders handed to the player, in play order, with the streams behind
    /// them. A stream's reader is cancelled once the player is done with it,
    /// so a decoder waiting for data never holds up the next track. (Holding
    /// the decoders keeps their identities unique.)
    private var handedOut: [(decoder: any PCMDecoding, release: (@Sendable () -> Void)?)] = []

    public init() {
        graph = ProcessingGraph(samples: samples)
        graph.onEvent = { [weak self] event in
            Task { @MainActor in self?.onEvent?(event) }
        }
        graph.onNowPlaying = { [weak self] decoder in
            Task { @MainActor in self?.released(before: decoder) }
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
        try play(.file(url))
    }

    /// Queues `url` to follow the current track without a gap.
    public func enqueue(_ url: URL) throws {
        try enqueue(.file(url))
    }

    /// Starts a file or a stream now, dropping anything queued. `gain` in dB
    /// (loudness normalization); the result changes it later.
    @discardableResult
    public func play(_ source: PlayableSource, gain: Double = 0) throws -> TrackGain {
        let track = TrackGain(try source.decoder(), decibels: gain)
        try player.play(track.decoder)
        releaseAll()
        handedOut = [(track.decoder, source.release)]
        return track
    }

    /// Starts a file at `fraction` of its length, dropping anything queued;
    /// playback stays paused if it was.
    @discardableResult
    public func play(_ url: URL, from fraction: Double, gain: Double = 0) throws -> TrackGain {
        let track = TrackGain(PositionedDecoder(decoder: try AudioDecoder(url: url), fraction: fraction), decibels: gain)
        if player.isPaused {
            try player.enqueue(track.decoder, immediate: true)
        } else {
            try player.play(track.decoder)
        }
        releaseAll()
        handedOut = [(track.decoder, nil)]
        return track
    }

    /// Queues a file or a stream to follow the current track without a gap.
    @discardableResult
    public func enqueue(_ source: PlayableSource, gain: Double = 0) throws -> TrackGain {
        let track = TrackGain(try source.decoder(), decibels: gain)
        try player.enqueue(track.decoder)
        handedOut.append((track.decoder, source.release))
        return track
    }

    /// Drops queued tracks the player hasn't started decoding. (Their
    /// streams are released once a later track plays: one the player had
    /// already picked up still plays and must keep reading.)
    public func clearQueue() {
        player.clearQueue()
    }

    public func pause() { player.pause() }
    public func resume() { player.resume() }

    public func stop() {
        player.stop()
        releaseAll()
        samples.clear()
    }

    private func releaseAll() {
        for entry in handedOut { entry.release?() }
        handedOut = []
    }

    /// The player moved on to `decoder`: everything handed out before it is done.
    private func released(before decoder: ObjectIdentifier) {
        guard let index = handedOut.firstIndex(where: { ObjectIdentifier($0.decoder) == decoder }) else { return }
        for entry in handedOut[..<index] { entry.release?() }
        handedOut.removeFirst(index)
    }

    public var state: EngineState {
        player.isPlaying ? .playing : player.isPaused ? .paused : .stopped
    }

    /// Streams can't seek until their download is complete.
    public var canSeek: Bool { player.supportsSeeking }

    /// The track being heard.
    public var nowPlayingURL: URL? { player.nowPlaying?.inputSource.url }

    /// Seconds into the current track.
    public var currentTime: Double? { player.currentTime.flatMap { $0.isFinite ? $0 : nil } }
    public var totalTime: Double? { player.totalTime.flatMap { $0.isFinite ? $0 : nil } }

    @discardableResult
    public func seek(to fraction: Double) -> Bool {
        player.seek(position: min(1, max(0, fraction)))
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

/// The gain of one track handed to the engine (loudness normalization).
public final class TrackGain: @unchecked Sendable {
    let decoder: GainDecoder

    init(_ decoder: any PCMDecoding, decibels: Double) {
        self.decoder = GainDecoder(decoder: decoder, gain: Self.linear(decibels))
        self.decibels = decibels
    }

    /// Set while the track plays, the level glides to the new gain.
    @MainActor public var decibels: Double {
        didSet { decoder.gain = Self.linear(decibels) }
    }

    /// Decoding has begun: the gain it began with is about to be heard.
    public var hasStarted: Bool { decoder.hasStarted }

    static func linear(_ decibels: Double) -> Float {
        Float(pow(10, decibels / 20))
    }
}

/// Owns the inserted nodes and receives SFBAudioEngine's delegate calls,
/// which arrive on the player's own threads.
final class ProcessingGraph: NSObject, AudioPlayer.Delegate, @unchecked Sendable {
    let equalizer = AVAudioUnitEQ(numberOfBands: 10)
    let balance = AVAudioMixerNode()
    private let samples: SampleBuffer
    var onEvent: (@Sendable (AudioEngine.Event) -> Void)?
    var onNowPlaying: (@Sendable (ObjectIdentifier) -> Void)?

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
        if let nowPlaying { onNowPlaying?(ObjectIdentifier(nowPlaying)) }
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

    /// A decoder that fails to open or decode (a damaged or unsupported file).
    func audioPlayer(_ audioPlayer: AudioPlayer, decodingAborted decoder: any PCMDecoding, error: any Error, framesRendered: AVAudioFramePosition) {
        onEvent?(.error(error.localizedDescription))
    }
}
