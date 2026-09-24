import Foundation

/// What the player shows about a track: tags and stream properties.
public struct TrackInfo: Sendable, Equatable, Codable {
    public var url: URL
    public var title: String?
    public var artist: String?
    public var album: String?
    /// Seconds.
    public var duration: Double?
    /// kbit/s.
    public var bitrate: Int?
    /// Hz.
    public var sampleRate: Double?
    public var channels: Int?

    public init(url: URL, title: String? = nil, artist: String? = nil, duration: Double? = nil) {
        self.url = url
        self.title = title
        self.artist = artist
        self.duration = duration
    }

    /// Winamp's default title format: "Artist - Title", else the file name.
    public var displayName: String {
        switch (artist?.nonEmpty, title?.nonEmpty) {
        case let (artist?, title?): "\(artist) - \(title)"
        case let (nil, title?): title
        default: url.isFileURL ? url.deletingPathExtension().lastPathComponent : url.absoluteString
        }
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
