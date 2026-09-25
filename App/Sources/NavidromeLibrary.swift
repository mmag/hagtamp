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
            LibraryView(title: "Favourites", lists: .artistsAndAlbums, reloadsWhenChosenAgain: true, listsFavourites: true),
            LibraryView(title: "Recently Added", lists: .albums),
            LibraryView(title: "Playlists", lists: .playlists, reloadsWhenChosenAgain: true),
            LibraryView(title: "Radio", lists: .stations),
        ]
    }

    var revision: String? { isConfigured ? server?.key : nil }
    var unavailableText: String { "Navidrome is not set up." }
    var setupTitle: String { "Preferences…" }
    func setUp() { (NSApp.delegate as? AppDelegate)?.showPreferences(tab: .navidrome) }
    var activity: String? {
        offlineProgress.map { "Downloading for offline: \($0.done) of \($0.total)" }
            ?? (offlineFailures > 0 ? "\(offlineFailures) song\(offlineFailures == 1 ? "" : "s") couldn't be downloaded for offline" : nil)
    }

    func isKeptOffline(_ item: LibraryItem) -> Bool? {
        switch item {
        case .album(let album): isKeptOffline(.album, id: album.id)
        case .playlist(let playlist): isKeptOffline(.playlist, id: playlist.id)
        case .artist, .track: nil
        }
    }

    func setKeptOffline(_ item: LibraryItem, _ keep: Bool) {
        switch item {
        case .album(let album): setKeptOffline(.album, id: album.id, name: album.name, keep)
        case .playlist(let playlist): setKeptOffline(.playlist, id: playlist.id, name: playlist.name, keep)
        case .artist, .track: break
        }
    }

    /// Favourites are what is starred on the server.
    func isFavourite(_ item: LibraryItem) -> Bool? {
        guard client != nil, let target = Self.starTarget(item) else { return nil }
        return isStarred(target)
    }

    func setFavourite(_ items: [LibraryItem], _ favourite: Bool) -> Task<Void, Error> {
        setStarred(items.compactMap(Self.starTarget), favourite)
    }

    /// Playlists can't be starred; tracks can when they are the server's songs.
    private static func starTarget(_ item: LibraryItem) -> NavidromeClient.StarTarget? {
        switch item {
        case .artist(let artist): .artist(artist.id)
        case .album(let album): .album(album.id)
        case .playlist: nil
        case .track(let info): NavidromeTrack.songID(from: info.url).map { .song($0) }
        }
    }

    var tracksHaveTags: Bool { true }

    // MARK: Playlists

    var editsPlaylists: Bool { client != nil }

    var editablePlaylists: [LibraryPlaylist] {
        playlists.filter(canEdit).map(libraryPlaylist)
    }

    func canAddToPlaylist(_ track: TrackInfo) -> Bool {
        client != nil && NavidromeTrack.songID(from: track.url) != nil
    }

    func createPlaylist(named name: String, with tracks: [TrackInfo]) async throws {
        try await connectedClient.createPlaylist(name: name, songIDs: tracks.compactMap { NavidromeTrack.songID(from: $0.url) })
        _ = try? await refreshPlaylists()
    }

    func add(_ tracks: [TrackInfo], to playlist: LibraryPlaylist) async throws {
        try await connectedClient.addToPlaylist(playlist.id, songIDs: tracks.compactMap { NavidromeTrack.songID(from: $0.url) })
        _ = try? await refreshPlaylists()
        // Kept offline, its new songs download too.
        if isKeptOffline(.playlist, id: playlist.id) { syncOffline() }
    }

    func deletePlaylist(_ playlist: LibraryPlaylist) async throws {
        try await connectedClient.deletePlaylist(playlist.id)
        if isKeptOffline(.playlist, id: playlist.id) { setKeptOffline(.playlist, id: playlist.id, name: playlist.name, false) }
        _ = try? await refreshPlaylists()
    }

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
            let starred = try await starredOnServer()
            return LibraryContent(
                artists: (starred.artist ?? []).map(Self.artist), albums: (starred.album ?? []).map(Self.album),
                tracks: (starred.song ?? []).map(Self.track))
        case 2:
            return LibraryContent(albums: try await client.albumList(.newest, size: 200).map(Self.album))
        case 3:
            return LibraryContent(playlists: try await refreshPlaylists().map(libraryPlaylist))
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

    private func libraryPlaylist(_ playlist: NavidromePlaylist) -> LibraryPlaylist {
        LibraryPlaylist(
            id: playlist.id, name: playlist.name, trackCount: playlist.songCount, duration: playlist.duration, editable: canEdit(playlist))
    }

    private static func track(_ song: NavidromeSong) -> LibraryTrack {
        LibraryTrack(info: NavidromeTrack.info(for: song), number: song.track)
    }
}
