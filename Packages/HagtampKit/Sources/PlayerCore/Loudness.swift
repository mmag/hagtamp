import Foundation

/// How loud a track is, as ReplayGain values: the gain in dB that brings
/// the track (and its album) to the reference loudness, and the peak sample
/// (1 = full scale) when known. Tags carry them; measuring gives them too
/// (`LoudnessMeasurement`).
public struct Loudness: Codable, Sendable, Equatable {
    /// ReplayGain 2.0's reference loudness, LUFS.
    public static let referenceLoudness = -18.0

    public var trackGain: Double
    public var trackPeak: Double?
    public var albumGain: Double?
    public var albumPeak: Double?

    public init(trackGain: Double, trackPeak: Double? = nil, albumGain: Double? = nil, albumPeak: Double? = nil) {
        self.trackGain = trackGain
        self.trackPeak = trackPeak
        self.albumGain = albumGain
        self.albumPeak = albumPeak
    }

    /// Values as tags and servers give them: a gain beyond reason or a peak
    /// that isn't positive counts as missing, and without a track gain there is nothing.
    public init?(tagged trackGain: Double?, trackPeak: Double?, albumGain: Double?, albumPeak: Double?) {
        func gain(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && abs($0) <= 60 ? $0 : nil } }
        func peak(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 > 0 && $0 < 100 ? $0 : nil } }
        guard let track = gain(trackGain) else { return nil }
        self.init(trackGain: track, trackPeak: peak(trackPeak), albumGain: gain(albumGain), albumPeak: peak(albumPeak))
    }
}

/// A track's loudness as measured (ITU-R BS.1770: K-weighted and gated),
/// kept in a form that combines with the rest of its album.
public struct LoudnessMeasurement: Codable, Sendable, Equatable {
    /// Integrated loudness, LUFS.
    public var loudness: Double
    /// 400 ms blocks that passed the gates: the track's weight in its album.
    public var blocks: Int
    /// The largest sample, 1 = full scale.
    public var peak: Double

    public init(loudness: Double, blocks: Int, peak: Double) {
        self.loudness = loudness
        self.blocks = blocks
        self.peak = peak
    }

    /// The ReplayGain gain, dB.
    public var gain: Double { Loudness.referenceLoudness - loudness }

    /// Tracks as one: their energies averaged by length. (BS.1770 would gate
    /// the album's blocks all together; for music the two agree to a fraction of a dB.)
    public static func combined(_ parts: some Collection<LoudnessMeasurement>) -> LoudnessMeasurement? {
        let blocks = parts.reduce(0) { $0 + $1.blocks }
        guard blocks > 0 else { return nil }
        let energy = parts.reduce(0.0) { $0 + Double($1.blocks) * pow(10, $1.loudness / 10) } / Double(blocks)
        return LoudnessMeasurement(loudness: 10 * log10(energy), blocks: blocks, peak: parts.map(\.peak).max() ?? 0)
    }
}

/// Loudness normalization as ReplayGain does it: each track is turned up or
/// down by one fixed amount so that it plays at the target loudness. Nothing
/// within a track changes (no compression), and a track is never turned up
/// so far that its peak would clip.
public struct Normalization: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Album gain while an album plays in order, track gain otherwise.
        case automatic
        case track
        case album
    }

    public var enabled = true
    public var mode = Mode.automatic
    /// LUFS.
    public var target = -16.0

    /// Targets offered: ReplayGain's reference and louder ones.
    public static let targets: [Double] = [-18, -16, -14, -12]

    /// What a track not measured yet most likely needs, before anything is
    /// measured: much of today's music is mastered around −10 LUFS.
    static let usualGain = -8.0

    public init(enabled: Bool = true, mode: Mode = .automatic, target: Double = -16) {
        self.enabled = enabled
        self.mode = mode
        self.target = target
    }

    /// Whether a track gets its album's gain: `continuesAlbum` when the
    /// entry before or after it in the playlist is from the same album.
    public func usesAlbumGain(shuffle: Bool, continuesAlbum: Bool) -> Bool {
        switch mode {
        case .automatic: !shuffle && continuesAlbum
        case .track: false
        case .album: true
        }
    }

    /// The gain for a track, dB (0 when off). A track whose loudness isn't
    /// known yet (`loudness` nil) gets `typicalGain`, what the tracks
    /// measured so far need, but never more than 0 dB: there is no peak to go by.
    public func gain(for loudness: Loudness?, album: Bool, typicalGain: Double?) -> Double {
        guard enabled else { return 0 }
        let preamp = target - Loudness.referenceLoudness
        guard let loudness else { return min(0, (typicalGain ?? Self.usualGain) + preamp) }
        let albumGain = album ? loudness.albumGain : nil
        let gain = (albumGain ?? loudness.trackGain) + preamp
        let peak = albumGain != nil ? loudness.albumPeak ?? loudness.trackPeak : loudness.trackPeak
        // The peak stays at or below full scale; without a peak, no turning up at all.
        let ceiling = peak.map { -20 * log10($0) } ?? 0
        return max(-40, min(gain, ceiling))
    }
}
