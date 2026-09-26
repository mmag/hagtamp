import Foundation

/// The loudness of every track read so far, by track key (a local file's
/// path, a server's song): from its tags or measured. A measured track's
/// album gain comes from the tracks of its album measured so far.
public struct LoudnessIndex: Sendable {
    public struct Record: Codable, Sendable, Equatable {
        /// The file's ReplayGain tags: someone chose them, so they win over measuring.
        public var tags: Loudness?
        public var measured: LoudnessMeasurement?
        /// Groups a measured track with the rest of its album.
        public var album: String?
        /// A local file's size and modification date when it was read: a
        /// file that changed is read again.
        public var size: Int64?
        public var modified: Date?

        public init(
            tags: Loudness? = nil, measured: LoudnessMeasurement? = nil, album: String? = nil, size: Int64? = nil, modified: Date? = nil
        ) {
            self.tags = tags
            self.measured = measured
            self.album = album
            self.size = size
            self.modified = modified
        }

        /// Whether the record still describes a file of this size and date
        /// (the index keeps dates to about a microsecond).
        public func matches(size: Int64?, modified: Date?) -> Bool {
            guard let size, let modified else { return self.size == nil && self.modified == nil }
            guard let ownModified = self.modified else { return false }
            return self.size == size && abs(ownModified.timeIntervalSince(modified)) < 0.001
        }
    }

    public private(set) var records: [String: Record] = [:]
    /// Measured tracks by album, and each album's combined measurement.
    private var albumTracks: [String: Set<String>] = [:]
    private var albums: [String: LoudnessMeasurement] = [:]

    public init(records: [String: Record] = [:]) {
        self.records = records
        for (key, record) in records {
            if let album = record.album, record.measured != nil { albumTracks[album, default: []].insert(key) }
        }
        for album in albumTracks.keys { combine(album) }
    }

    public var count: Int { records.count }

    public subscript(key: String) -> Record? {
        get { records[key] }
        set {
            let old = records[key]?.album
            records[key] = newValue
            if let old { albumTracks[old]?.remove(key) }
            if let album = newValue?.album, newValue?.measured != nil { albumTracks[album, default: []].insert(key) }
            for album in Set([old, newValue?.album].compactMap { $0 }) { combine(album) }
        }
    }

    /// Track and album gains of a track: its tags, else its measurement and
    /// its album's so far.
    public func loudness(for key: String) -> Loudness? {
        guard let record = records[key] else { return nil }
        if let tags = record.tags { return tags }
        guard let measured = record.measured else { return nil }
        let album = record.album.flatMap { albums[$0] }
        return Loudness(trackGain: measured.gain, trackPeak: measured.peak, albumGain: album?.gain, albumPeak: album?.peak)
    }

    /// The median track gain: what a track not read yet most likely needs.
    public var typicalGain: Double? {
        let gains = records.values.compactMap { $0.tags?.trackGain ?? $0.measured?.gain }.sorted()
        guard !gains.isEmpty else { return nil }
        let middle = gains.count / 2
        return gains.count % 2 == 1 ? gains[middle] : (gains[middle - 1] + gains[middle]) / 2
    }

    public mutating func removeAll(where shouldRemove: (String, Record) -> Bool) {
        for (key, record) in records where shouldRemove(key, record) { self[key] = nil }
    }

    private mutating func combine(_ album: String) {
        let tracks = albumTracks[album] ?? []
        if tracks.isEmpty { albumTracks[album] = nil }
        albums[album] = LoudnessMeasurement.combined(tracks.compactMap { records[$0]?.measured })
    }
}

extension LoudnessIndex: Codable {
    private struct Saved: Codable {
        var version = 1
        var records: [String: Record]
    }

    public init(from decoder: Decoder) throws {
        self.init(records: try Saved(from: decoder).records)
    }

    public func encode(to encoder: Encoder) throws {
        try Saved(records: records).encode(to: encoder)
    }
}
