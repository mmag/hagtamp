import Foundation

// Subsonic API (1.16.1) objects as Navidrome returns them. Optional fields
// stay optional: servers leave out what they don't know.

public struct NavidromeArtist: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var albumCount: Int?
    public var coverArt: String?
}

public struct NavidromeAlbum: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var artist: String?
    public var artistId: String?
    public var year: Int?
    public var songCount: Int?
    /// Seconds.
    public var duration: Int?
    public var coverArt: String?
    public var created: String?
    public var song: [NavidromeSong]?
}

public struct NavidromeSong: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var album: String?
    public var albumId: String?
    public var artist: String?
    public var artistId: String?
    public var track: Int?
    public var discNumber: Int?
    public var year: Int?
    /// Seconds.
    public var duration: Int?
    /// kbit/s of the stored file.
    public var bitRate: Int?
    /// Hz (OpenSubsonic).
    public var samplingRate: Int?
    public var channelCount: Int?
    public var suffix: String?
    public var contentType: String?
    public var size: Int?
    public var coverArt: String?
}

public struct NavidromePlaylist: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var songCount: Int?
    public var duration: Int?
    public var owner: String?
    /// Smart playlists can't be changed (OpenSubsonic).
    public var readonly: Bool?
    public var coverArt: String?
    public var entry: [NavidromeSong]?
}

public struct NavidromeRadioStation: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var streamUrl: String
    public var homePageUrl: String?
}

public struct NavidromeSearchResult: Codable, Hashable, Sendable {
    public var artist: [NavidromeArtist]?
    public var album: [NavidromeAlbum]?
    public var song: [NavidromeSong]?
}

/// An error reported by the server in the Subsonic envelope.
public struct NavidromeError: Error, Equatable, LocalizedError, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    public static let wrongCredentials = 40
}
