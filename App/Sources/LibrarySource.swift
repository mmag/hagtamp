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
    /// Can be added to and deleted here (not someone else's, not a smart playlist).
    var editable = true
}

struct LibraryTrack: Sendable {
    var info: TrackInfo
    var number: Int?
}

/// Something a menu acts on: kept offline, made a favourite.
enum LibraryItem {
    case artist(LibraryArtist)
    case album(LibraryAlbum)
    case playlist(LibraryPlaylist)
    /// A library's track, or a playlist entry.
    case track(TrackInfo)
}

/// A library's own complaint (a playlist name taken).
struct LibraryError: LocalizedError {
    var errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
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
    /// Lists the favourites: it reloads when some are removed from its menus.
    var listsFavourites = false
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

    /// Whether an album or playlist is kept offline; nil where that makes no sense (local files).
    func isKeptOffline(_ item: LibraryItem) -> Bool?
    func setKeptOffline(_ item: LibraryItem, _ keep: Bool)

    /// Whether an artist, album or track is a favourite; nil where there are none (local files, radio).
    func isFavourite(_ item: LibraryItem) -> Bool?
    /// Adds to or removes from the favourites (those that can be one) at once;
    /// the task ends when the library has it.
    @discardableResult
    func setFavourite(_ items: [LibraryItem], _ favourite: Bool) -> Task<Void, Error>

    /// Whether playlists can be made, added to and deleted here.
    var editsPlaylists: Bool { get }
    /// The playlists tracks can be added to, as last listed (a menu can't wait for a server).
    var editablePlaylists: [LibraryPlaylist] { get }
    /// Whether a track can go into this library's playlists: its own songs or files.
    func canAddToPlaylist(_ track: TrackInfo) -> Bool
    func createPlaylist(named name: String, with tracks: [TrackInfo]) async throws
    /// Adds at the end (the tracks this library can take).
    func add(_ tracks: [TrackInfo], to playlist: LibraryPlaylist) async throws
    func deletePlaylist(_ playlist: LibraryPlaylist) async throws
}

extension LibrarySource {
    func isKeptOffline(_ item: LibraryItem) -> Bool? { nil }
    func setKeptOffline(_ item: LibraryItem, _ keep: Bool) {}
    func isFavourite(_ item: LibraryItem) -> Bool? { nil }
    func setFavourite(_ items: [LibraryItem], _ favourite: Bool) -> Task<Void, Error> { Task {} }
    var editsPlaylists: Bool { false }
    var editablePlaylists: [LibraryPlaylist] { [] }
    func canAddToPlaylist(_ track: TrackInfo) -> Bool { false }
    func createPlaylist(named name: String, with tracks: [TrackInfo]) async throws {}
    func add(_ tracks: [TrackInfo], to playlist: LibraryPlaylist) async throws {}
    func deletePlaylist(_ playlist: LibraryPlaylist) async throws {}

    func tracks(of item: LibraryItem) async throws -> [LibraryTrack] {
        switch item {
        case .artist(let artist): try await tracks(of: albums(of: artist))
        case .album(let album): try await tracks(of: [album])
        case .playlist(let playlist): try await tracks(of: playlist)
        case .track(let info): [LibraryTrack(info: info)]
        }
    }
}
