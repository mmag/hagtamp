import Foundation
import PlayerCore

/// What a library window lists. Each library maps its own records onto these.
struct LibraryArtist: Sendable {
    var id: String
    var name: String
    var albumCount: Int?
}

struct LibraryAlbum: Sendable {
    var id: String
    var name: String
    var artist: String?
    var year: Int?
}

struct LibraryPlaylist: Sendable {
    var id: String
    var name: String
    var trackCount: Int?
    /// Seconds.
    var duration: Int?
}

struct LibraryTrack: Sendable {
    var info: TrackInfo
    var number: Int?
}

/// The lists of a view, or search results.
struct LibraryContent: Sendable {
    var artists: [LibraryArtist] = []
    var albums: [LibraryAlbum] = []
    var playlists: [LibraryPlaylist] = []
    var tracks: [LibraryTrack] = []
}

/// A sidebar entry.
struct LibraryView {
    enum Lists {
        /// Artists | albums above the tracks.
        case artistsAndAlbums
        case albums
        case playlists
        /// Just the track list, of radio stations.
        case stations
    }

    var title: String
    var lists: Lists
    /// Choosing the view again reloads it (it changes elsewhere, like server favourites).
    var reloadsWhenChosenAgain = false
}

/// A library browsed in a `LibraryWindowController`: Navidrome or the local files.
@MainActor
protocol LibrarySource: AnyObject {
    var windowTitle: String { get }
    /// The first one lists artists and albums and shows search results.
    var views: [LibraryView] { get }
    /// Stands for the library's contents; the window reloads when it changes. nil: nothing to browse yet.
    var revision: String? { get }
    /// Status while there is nothing to browse, and the button that fixes that.
    var unavailableText: String { get }
    var setupTitle: String { get }
    func setUp()
    /// Work in progress to show instead of the track count ("Scanning…").
    var activity: String? { get }
    /// The tracks come with complete tags, so the playlist needn't read the files.
    var tracksHaveTags: Bool { get }
    /// Called when `revision` or `activity` changes.
    var onChange: (() -> Void)? { get set }

    func content(ofView index: Int) async throws -> LibraryContent
    func albums(of artist: LibraryArtist) async throws -> [LibraryAlbum]
    func tracks(of albums: [LibraryAlbum]) async throws -> [LibraryTrack]
    func tracks(of playlist: LibraryPlaylist) async throws -> [LibraryTrack]
    func search(_ query: String) async throws -> LibraryContent
}
