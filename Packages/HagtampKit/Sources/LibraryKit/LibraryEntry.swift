import Foundation
import PlayerCore
@preconcurrency import SFBAudioEngine

/// One audio file in the local library: its tags and stream properties, and
/// what a rescan needs to tell whether the file changed.
public struct LibraryEntry: Codable, Sendable, Equatable {
    public var url: URL
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    /// Seconds.
    public var duration: Double?
    /// kbit/s.
    public var bitrate: Int?
    public var sampleRate: Double?
    public var channels: Int?
    public var fileSize: Int64
    public var modified: Date
    /// When the file joined the library: its creation date when first indexed.
    public var added: Date

    public init(url: URL, fileSize: Int64 = 0, modified: Date = .distantPast, added: Date = .distantPast) {
        self.url = url
        self.fileSize = fileSize
        self.modified = modified
        self.added = added
    }

    /// Reads the file's tags; unreadable files keep just their name.
    public static func read(_ url: URL, fileSize: Int64, modified: Date, added: Date) -> LibraryEntry {
        var entry = LibraryEntry(url: url, fileSize: fileSize, modified: modified, added: added)
        guard let file = try? AudioFile(readingPropertiesAndMetadataFrom: url) else { return entry }
        let tags = file.metadata
        entry.title = tags.title?.nonEmptyTag
        entry.artist = tags.artist?.nonEmptyTag
        entry.albumArtist = tags.albumArtist?.nonEmptyTag
        entry.album = tags.albumTitle?.nonEmptyTag
        entry.genre = tags.genre?.nonEmptyTag
        entry.year = tags.releaseDate.flatMap(Self.year(from:))
        entry.trackNumber = tags.trackNumber
        entry.discNumber = tags.discNumber
        let properties = file.properties
        entry.duration = properties.duration
        entry.sampleRate = properties.sampleRate
        entry.channels = properties.channelCount.map(Int.init)
        entry.bitrate = properties.bitrate.map { Int($0.rounded()) }
        return entry
    }

    /// "1987", "1987-05-01", "1987-05-01T00:00:00Z" and so on.
    static func year(from date: String) -> Int? {
        let digits = date.prefix { $0.isNumber }
        guard digits.count == 4, let year = Int(digits), year > 0 else { return nil }
        return year
    }

    /// What the playlist shows.
    public var info: TrackInfo {
        var info = TrackInfo(url: url, title: title, artist: artist, duration: duration)
        info.album = album
        info.bitrate = bitrate
        info.sampleRate = sampleRate
        info.channels = channels
        return info
    }

    /// The title, else the file name.
    public var displayTitle: String {
        title ?? url.deletingPathExtension().lastPathComponent
    }
}

extension String {
    var nonEmptyTag: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Case- and accent-insensitive form for grouping and searching.
    var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
