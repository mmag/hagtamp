import Foundation

/// The local library grouped for browsing: artists, their albums, and the
/// tracks of each album.
///
/// An album is its album tag plus its album artist. Without an album
/// artist tag, an album whose tracks in one folder have different artists
/// is a compilation ("Various Artists"); otherwise the track artist counts.
/// So discs in subfolders (CD1, CD2) share an album, and compilations
/// don't break up into one album per artist.
public struct LibraryCatalog: Sendable {
    public struct Artist: Sendable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public var albumCount: Int
    }

    public struct Album: Sendable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public var artist: String
        public var artistID: String
        public var year: Int?
        /// The newest file's `added` date.
        public var added: Date
    }

    public static let unknownArtist = "Unknown Artist"
    public static let unknownAlbum = "Unknown Album"
    public static let variousArtists = "Various Artists"

    /// Sorted by name.
    public private(set) var artists: [Artist] = []
    /// Sorted by artist, year, name.
    public private(set) var albums: [Album] = []
    public private(set) var trackCount = 0
    private var albumsByArtist: [String: [Album]] = [:]
    private var tracksByAlbum: [String: [LibraryEntry]] = [:]
    /// Folded "title artist album album-artist" per track, for search.
    private var searchText: [URL: String] = [:]

    public init() {}

    public init<Entries: Collection<LibraryEntry>>(_ entries: Entries) {
        trackCount = entries.count

        // Album artists: the tag, else the folder's artist(s) for that album.
        var folderArtists: [FolderAlbum: Set<String>] = [:]
        for entry in entries where entry.albumArtist == nil {
            let key = FolderAlbum(folder: entry.url.deletingLastPathComponent().path, album: entry.album?.folded ?? "")
            folderArtists[key, default: []].insert(entry.artist?.folded ?? "")
        }
        func albumArtist(_ entry: LibraryEntry) -> String {
            if let tagged = entry.albumArtist { return tagged }
            let key = FolderAlbum(folder: entry.url.deletingLastPathComponent().path, album: entry.album?.folded ?? "")
            if entry.album != nil, (folderArtists[key]?.count ?? 0) > 1 { return Self.variousArtists }
            return entry.artist ?? Self.unknownArtist
        }

        var artistNames: [String: String] = [:]
        var albumsByID: [String: Album] = [:]
        for entry in entries {
            let artistName = albumArtist(entry)
            let artistID = artistName.folded
            artistNames[artistID] = artistNames[artistID] ?? artistName
            let albumName = entry.album ?? Self.unknownAlbum
            let albumID = artistID + "\u{1F}" + albumName.folded
            var album = albumsByID[albumID] ?? Album(
                id: albumID, name: albumName, artist: artistName, artistID: artistID, year: nil, added: entry.added)
            if let year = entry.year { album.year = max(album.year ?? year, year) }
            album.added = max(album.added, entry.added)
            albumsByID[albumID] = album
            tracksByAlbum[albumID, default: []].append(entry)
            searchText[entry.url] = [entry.title ?? entry.displayTitle, entry.artist, entry.album, entry.albumArtist]
                .compactMap { $0 }.joined(separator: " ").folded
        }
        for (id, tracks) in tracksByAlbum {
            tracksByAlbum[id] = tracks.sorted(by: Self.trackOrder)
        }

        albums = albumsByID.values.sorted(by: Self.albumOrder)
        albumsByArtist = Dictionary(grouping: albums, by: \.artistID)
        artists = albumsByArtist.map { id, albums in Artist(id: id, name: artistNames[id] ?? id, albumCount: albums.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct FolderAlbum: Hashable {
        var folder: String
        var album: String
    }

    public func albums(ofArtist id: String) -> [Album] {
        albumsByArtist[id] ?? []
    }

    public func tracks(ofAlbum id: String) -> [LibraryEntry] {
        tracksByAlbum[id] ?? []
    }

    /// Albums, newest additions first.
    public var recentlyAdded: [Album] {
        albums.sorted { $0.added > $1.added }
    }

    /// Everything matching every word of `query`, ignoring case and accents.
    public func search(_ query: String) -> (artists: [Artist], albums: [Album], tracks: [LibraryEntry]) {
        let words = query.folded.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return ([], [], []) }
        func matches(_ text: String) -> Bool { words.allSatisfy { text.contains($0) } }
        let foundArtists = artists.filter { matches($0.name.folded) }
        let foundAlbums = albums.filter { matches("\($0.name) \($0.artist)".folded) }
        let foundTracks = albums.flatMap { album in
            tracks(ofAlbum: album.id).filter { matches(searchText[$0.url] ?? "") }
        }
        return (foundArtists, foundAlbums, foundTracks)
    }

    static func albumOrder(_ a: Album, _ b: Album) -> Bool {
        if a.artistID != b.artistID { return a.artist.localizedStandardCompare(b.artist) == .orderedAscending }
        if a.year != b.year { return (a.year ?? 0) < (b.year ?? 0) }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// Disc, track number, then file name.
    static func trackOrder(_ a: LibraryEntry, _ b: LibraryEntry) -> Bool {
        if (a.discNumber ?? 1) != (b.discNumber ?? 1) { return (a.discNumber ?? 1) < (b.discNumber ?? 1) }
        if a.trackNumber != b.trackNumber { return (a.trackNumber ?? .max) < (b.trackNumber ?? .max) }
        return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
    }
}
