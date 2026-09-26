import AVFAudio
import Accelerate
import Foundation
import PlayerCore
@preconcurrency import SFBAudioEngine

/// Integrated loudness as ITU-R BS.1770-4 (EBU R128) measures it: the
/// K-weighted mean square of 400 ms blocks overlapping by 75%, gated at
/// −70 LUFS and then at 10 LU below the loudness of the blocks left; and
/// the sample peak.
public struct LoudnessMeter {
    /// Channel weights: mono counts as the same signal on two speakers.
    private let weights: [Double]
    private var filters: [vDSP.Biquad<Float>]
    /// A quarter block, 100 ms.
    private let stepLength: Int
    private var stepEnergy = 0.0
    private var stepFill = 0
    /// Mean squares of the last quarter blocks, weighted and summed over the channels.
    private var recentSteps: [Double] = []
    private var blocks: [Double] = []
    private var peak: Float = 0
    private var filtered: [Float] = []

    /// nil for a format it can't measure.
    public init?(sampleRate: Double, channelCount: Int) {
        guard sampleRate >= 8000, sampleRate.isFinite, channelCount > 0 else { return nil }
        // 5.1 in its usual order has an LFE channel (left out) and surrounds (weighted up).
        weights =
            channelCount == 1 ? [2]
            : channelCount == 6 ? [1, 1, 1, 0, 1.41, 1.41] : Array(repeating: 1, count: channelCount)
        let coefficients = Self.kWeighting(sampleRate: sampleRate)
        var filters: [vDSP.Biquad<Float>] = []
        for _ in 0..<channelCount {
            guard let filter = vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: 2, ofType: Float.self) else {
                return nil
            }
            filters.append(filter)
        }
        self.filters = filters
        stepLength = max(1, Int((sampleRate / 10).rounded()))
    }

    /// The two stages of the K filter (a high shelf for the head, a high-pass
    /// for the low end) at any sample rate, as libebur128 derives them.
    /// Each section is b0, b1, b2, a1, a2.
    static func kWeighting(sampleRate: Double) -> [Double] {
        var f0 = 1681.974450955533, q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        var k = tan(.pi * f0 / sampleRate)
        let a0 = 1 + k / q + k * k
        let shelf = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(.pi * f0 / sampleRate)
        let d = 1 + k / q + k * k
        let highPass = [1, -2, 1, 2 * (k * k - 1) / d, (1 - k / q + k * k) / d]
        return shelf + highPass
    }

    /// Takes deinterleaved float samples, as many channels as the meter has.
    public mutating func process(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData, Int(buffer.format.channelCount) == weights.count else { return }
        // Stretches of the buffer that end where a quarter block does.
        var stretches: [Range<Int>] = []
        var start = 0, fill = stepFill
        while start < frames {
            let length = min(frames - start, stepLength - fill)
            stretches.append(start..<start + length)
            start += length
            fill = (fill + length) % stepLength
        }
        if filtered.count != frames { filtered = [Float](repeating: 0, count: frames) }
        var energies = [Double](repeating: 0, count: stretches.count)
        for channel in weights.indices {
            let samples = UnsafeBufferPointer(start: data[channel], count: frames)
            peak = max(peak, vDSP.maximumMagnitude(samples))
            guard weights[channel] > 0 else { continue }
            filters[channel].apply(input: samples, output: &filtered)
            for (i, stretch) in stretches.enumerated() {
                energies[i] += weights[channel] * Double(vDSP.sumOfSquares(filtered[stretch]))
            }
        }
        for (i, stretch) in stretches.enumerated() {
            stepEnergy += energies[i]
            stepFill += stretch.count
            if stepFill == stepLength { finishStep() }
        }
    }

    private mutating func finishStep() {
        recentSteps.append(stepEnergy / Double(stepLength))
        stepEnergy = 0
        stepFill = 0
        if recentSteps.count > 4 { recentSteps.removeFirst() }
        if recentSteps.count == 4 { blocks.append(recentSteps.reduce(0, +) / 4) }
    }

    /// The loudness of what was processed; nil for less than 400 ms of sound.
    public var measurement: LoudnessMeasurement? {
        func loudness(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        let audible = blocks.filter { loudness($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let gate = loudness(mean(audible)) - 10
        let gated = audible.filter { loudness($0) > gate }
        guard !gated.isEmpty else { return nil }
        return LoudnessMeasurement(loudness: loudness(mean(gated)), blocks: gated.count, peak: Double(peak))
    }
}

/// What reading a file for its loudness found: its ReplayGain tags, or a
/// measurement when it has none, and the album it belongs to.
public struct LoudnessReading: Sendable, Equatable {
    public var tags: Loudness?
    public var measured: LoudnessMeasurement?
    /// The album artist (else artist) and album tags, folded; nil without an album tag.
    public var album: String?

    /// Reads the tags and, without ReplayGain tags, decodes the whole file
    /// to measure it: slow, for a background thread. nil when the file
    /// can't be decoded.
    public static func read(_ url: URL) -> LoudnessReading? {
        var reading = LoudnessReading()
        if let tags = try? AudioFile(readingPropertiesAndMetadataFrom: url).metadata {
            reading.tags = Loudness(
                tagged: tags.replayGainTrackGain, trackPeak: tags.replayGainTrackPeak, albumGain: tags.replayGainAlbumGain,
                albumPeak: tags.replayGainAlbumPeak)
            if let album = tags.albumTitle?.folded, !album.isEmpty {
                reading.album = ((tags.albumArtist ?? tags.artist)?.folded ?? "") + "\u{1F}" + album
            }
        }
        if reading.tags == nil {
            guard let measured = try? measure(url) else { return nil }
            reading.measured = measured
        }
        return reading
    }

    static func measure(_ url: URL) throws -> LoudnessMeasurement? {
        // mpg123's decoder setup isn't thread-safe, and the player opens its
        // decoders meanwhile: here MP3 goes through Core Audio.
        let decoder =
            url.pathExtension.lowercased() == "mp3" ? try AudioDecoder(url: url, decoderName: .coreAudio) : try AudioDecoder(url: url)
        try decoder.open()
        defer { try? decoder.close() }
        let format = decoder.processingFormat
        let float =
            format.channelLayout.map { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, interleaved: false, channelLayout: $0) }
            ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: format.channelCount, interleaved: false)
        guard let float, var meter = LoudnessMeter(sampleRate: format.sampleRate, channelCount: Int(format.channelCount)),
            let decoded = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)
        else { return nil }
        var converter: AVAudioConverter?
        if format != float {
            guard let made = AVAudioConverter(from: format, to: float) else { return nil }
            converter = made
        }
        guard let converted = converter == nil ? decoded : AVAudioPCMBuffer(pcmFormat: float, frameCapacity: 4096) else { return nil }
        while true {
            try decoder.decode(into: decoded, length: decoded.frameCapacity)
            guard decoded.frameLength > 0 else { break }
            try converter?.convert(to: converted, from: decoded)
            meter.process(converted)
        }
        return meter.measurement
    }
}

extension String {
    /// Case- and accent-insensitive, trimmed.
    fileprivate var folded: String {
        trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
