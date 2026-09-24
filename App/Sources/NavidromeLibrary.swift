import AppKit
import NavidromeKit
import PlayerCore

/// Navidrome as a library: artists, favourites (starred on the server),
/// recently added albums, playlists and internet radio stations.
extension NavidromeService: LibrarySource {
    var windowTitle: String { "Navidrome" }

    var views: [LibraryView] {
        [
            LibraryView(title: "Library", lists: .artistsAndAlbums),
            LibraryView(title: "Favourites", lists: .artistsAndAlbums, reloadsWhenChosenAgain: true),
            LibraryView(title: "Recently Added", lists: .albums),
            LibraryView(title: "Playlists", lists: .playlists),
            LibraryView(title: "Radio", lists: .stations),
        ]
    }

    var revision: String? { isConfigured ? server?.key : nil }
    var unavailableText: String { "Navidrome is not set up." }
    var setupTitle: String { "Preferences…" }
    func setUp() { (NSApp.delegate as? AppDelegate)?.showPreferences(nil) }
    var activity: String? { nil }
    var tracksHaveTags: Bool { true }

    private var connectedClient: NavidromeClient {
        get throws {
            guard let client else { throw NavidromeError(code: -1, message: "Navidrome is not set up.") }
            return client
        }
    }

    func content(ofView index: Int) async throws -> LibraryContent {
        let client = try connectedClient
        switch index {
        case 0:
            return LibraryContent(artists: try await client.artists().map(Self.artist))
        case 1:
            let starred = try await client.starred()
            return LibraryContent(
                artists: (starred.artist ?? []).map(Self.artist), albums: (starred.album ?? []).map(Self.album),
                tracks: (starred.song ?? []).map(Self.track))
        case 2:
            return LibraryContent(albums: try await client.albumList(.newest, size: 200).map(Self.album))
        case 3:
            return LibraryContent(playlists: try await client.playlists().map(Self.playlist))
        default:
            let stations = try await client.radioStations().compactMap { station in
                URL(string: station.streamUrl).map { LibraryTrack(info: TrackInfo(url: $0, title: station.name), number: nil) }
            }
            return LibraryContent(tracks: stations)
        }
    }

    func albums(of artist: LibraryArtist) async throws -> [LibraryAlbum] {
        try await connectedClient.albums(ofArtist: artist.id).map(Self.album)
    }

    /// Albums load in parallel and keep their order.
    func tracks(of albums: [LibraryAlbum]) async throws -> [LibraryTrack] {
        let client = try connectedClient
        let ids = albums.map(\.id)
        let songs = try await withThrowingTaskGroup(of: (Int, [NavidromeSong]).self) { group in
            for (i, id) in ids.enumerated() {
                group.addTask { (i, try await client.album(id).song ?? []) }
            }
            var parts: [(Int, [NavidromeSong])] = []
            for try await part in group { parts.append(part) }
            return parts.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        return songs.map(Self.track)
    }

    func tracks(of playlist: LibraryPlaylist) async throws -> [LibraryTrack] {
        (try await connectedClient.playlist(playlist.id).entry ?? []).map(Self.track)
    }

    func search(_ query: String) async throws -> LibraryContent {
        let results = try await connectedClient.search(query)
        // Found songs come by relevance; list them album by album.
        let songs = (results.song ?? []).sorted {
            ($0.album ?? "", $0.discNumber ?? 0, $0.track ?? 0) < ($1.album ?? "", $1.discNumber ?? 0, $1.track ?? 0)
        }
        return LibraryContent(
            artists: (results.artist ?? []).map(Self.artist), albums: (results.album ?? []).map(Self.album),
            tracks: songs.map(Self.track))
    }

    private static func artist(_ artist: NavidromeArtist) -> LibraryArtist {
        LibraryArtist(id: artist.id, name: artist.name, albumCount: artist.albumCount)
    }

    private static func album(_ album: NavidromeAlbum) -> LibraryAlbum {
        LibraryAlbum(id: album.id, name: album.name, artist: album.artist, year: album.year)
    }

    private static func playlist(_ playlist: NavidromePlaylist) -> LibraryPlaylist {
        LibraryPlaylist(id: playlist.id, name: playlist.name, trackCount: playlist.songCount, duration: playlist.duration)
    }

    private static func track(_ song: NavidromeSong) -> LibraryTrack {
        LibraryTrack(info: NavidromeTrack.info(for: song), number: song.track)
    }
}
