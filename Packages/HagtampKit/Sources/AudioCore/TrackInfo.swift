import Foundation
import SFBAudioEngine

/// What the player shows about a track: tags and stream properties.
public struct TrackInfo: Sendable, Equatable {
    public var url: URL
    public var title: String?
    public var artist: String?
    public var album: String?
    /// Seconds.
    public var duration: Double?
    public var bitrate: Int?
    /// Hz.
    public var sampleRate: Double?
    public var channels: Int?

    public init(url: URL) {
        self.url = url
    }

    /// Winamp's default title format: "Artist - Title", else the file name.
    public var displayName: String {
        switch (artist?.nonEmpty, title?.nonEmpty) {
        case let (artist?, title?): "\(artist) - \(title)"
        case let (nil, title?): title
        default: url.deletingPathExtension().lastPathComponent
        }
    }

    /// Reads tags and properties; files the decoders can't parse still get a name.
    public static func read(from url: URL) -> TrackInfo {
        var info = TrackInfo(url: url)
        guard let file = try? AudioFile(readingPropertiesAndMetadataFrom: url) else { return info }
        info.title = file.metadata.title
        info.artist = file.metadata.artist
        info.album = file.metadata.albumTitle
        let properties = file.properties
        info.duration = properties.duration
        info.sampleRate = properties.sampleRate
        info.channels = properties.channelCount.map(Int.init)
        info.bitrate = properties.bitrate.map { Int($0.rounded()) }
        return info
    }

    /// File extensions the decoders handle (for open panels and folder scans).
    public static var supportedExtensions: Set<String> {
        AudioDecoder.supportedPathExtensions
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
