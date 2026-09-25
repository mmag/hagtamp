import AppKit
import AudioCore
import LibraryKit
import PlayerCore

/// The local library in the app: its folders (settings), the index kept up
/// to date in the background, and browsing for the library window.
@MainActor
final class LocalLibraryService: LibrarySource {
    private static let foldersKey = "library.folders"

    private let library: LocalLibrary
    private(set) var folders: [URL]
    private(set) var catalog = LibraryCatalog()
    private var favourites: LibraryFavourites
    private var catalogRevision = 0
    private(set) var progress: ScanProgress?
    private var lastProgressReport = Date.distantPast
    /// Rescans when files change in the folders.
    private var watcher: FolderWatcher?
    var onChange: (() -> Void)?
    /// Preferences follow the folders and scanning too.
    var onStatusChange: (() -> Void)?

    init() {
        folders = (Storage.defaults.stringArray(forKey: Self.foldersKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        library = LocalLibrary(indexFile: Storage.supportDirectory.appendingPathComponent("library.json"))
        favourites = (try? Data(contentsOf: Self.favouritesFile)).flatMap { try? JSONDecoder().decode(LibraryFavourites.self, from: $0) }
            ?? LibraryFavourites()
        let library = self.library, folders = self.folders
        Task {
            await library.observe(
                catalog: { catalog in Task { @MainActor [weak self] in self?.catalogChanged(catalog) } },
                progress: { progress in Task { @MainActor [weak self] in self?.progressChanged(progress) } })
            await library.open(folders: folders)
        }
        watch()
    }

    private func watch() {
        let library = self.library
        watcher = FolderWatcher(folders, extensions: TrackInfo.supportedExtensions, ignoring: [Storage.supportDirectory, Storage.cacheDirectory]) {
            Task { await library.rescan() }
        }
    }

    // MARK: - Folders

    func setFolders(_ folders: [URL]) {
        var unique: [URL] = []
        for folder in folders.map(\.standardizedFileURL) where !unique.contains(folder) { unique.append(folder) }
        self.folders = unique
        Storage.defaults.set(unique.map(\.path), forKey: Self.foldersKey)
        let library = self.library
        Task { await library.setFolders(unique) }
        watch()
        changed()
    }

    /// Asks for folders to add.
    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders with music for the library"
        guard panel.runModal() == .OK else { return }
        setFolders(folders + panel.urls)
    }

    func removeFolder(_ folder: URL) {
        setFolders(folders.filter { $0 != folder })
    }

    func rescan() {
        let library = self.library
        Task { await library.rescan() }
    }

    /// For the preferences: "1234 tracks" or the scan's progress.
    var statusText: String {
        if let activity { return activity }
        return folders.isEmpty ? "No folders" : "\(catalog.trackCount) \(catalog.trackCount == 1 ? "track" : "tracks")"
    }

    private func catalogChanged(_ catalog: LibraryCatalog) {
        self.catalog = catalog
        catalogRevision += 1
        changed()
    }

    private func progressChanged(_ progress: ScanProgress?) {
        self.progress = progress
        // Several times a second is plenty for a status line.
        guard progress == nil || Date().timeIntervalSince(lastProgressReport) > 0.25 else { return }
        lastProgressReport = Date()
        changed()
    }

    private func changed() {
        onChange?()
        onStatusChange?()
    }

    // MARK: - LibrarySource

    var windowTitle: String { "Local Library" }

    var views: [LibraryView] {
        [
            LibraryView(title: "Audio", lists: .artistsAndAlbums),
            // Reloads when chosen again: the playlist's menu changes favourites too.
            LibraryView(title: "Favourites", lists: .artistsAndAlbums, reloadsWhenChosenAgain: true, listsFavourites: true),
            LibraryView(title: "Recently Added", lists: .albums),
            LibraryView(title: "Playlists", lists: .playlists, reloadsWhenChosenAgain: true),
        ]
    }

    var revision: String? { folders.isEmpty ? nil : "\(catalogRevision)" }
    var unavailableText: String { "No folders in the library." }
    var setupTitle: String { "Add Folder…" }
    func setUp() { addFolders() }
    var tracksHaveTags: Bool { true }

    var activity: String? {
        progress.map { "Scanning… \($0.read) of \($0.total) files" }
    }

    func content(ofView index: Int) async throws -> LibraryContent {
        switch index {
        case 0:
            return LibraryContent(artists: catalog.artists.map(Self.artist))
        case 1:
            let found = catalog.favourites(favourites)
            return LibraryContent(artists: found.artists.map(Self.artist), albums: found.albums.map(Self.album), tracks: found.tracks.map(Self.track))
        case 2:
            return LibraryContent(albums: catalog.recentlyAdded.map(Self.album))
        default:
            return LibraryContent(playlists: editablePlaylists)
        }
    }

    func albums(of artist: LibraryArtist) async throws -> [LibraryAlbum] {
        catalog.albums(ofArtist: artist.id).map(Self.album)
    }

    func tracks(of albums: [LibraryAlbum]) async throws -> [LibraryTrack] {
        albums.flatMap { catalog.tracks(ofAlbum: $0.id) }.map(Self.track)
    }

    /// A playlist's files with their tags from the library.
    func tracks(of playlist: LibraryPlaylist) async throws -> [LibraryTrack] {
        try PlaylistFile.read(URL(fileURLWithPath: playlist.id)).map { info in
            catalog.entry(at: info.url).map(Self.track) ?? LibraryTrack(info: info)
        }
    }

    func search(_ query: String) async throws -> LibraryContent {
        let found = catalog.search(query)
        return LibraryContent(artists: found.artists.map(Self.artist), albums: found.albums.map(Self.album), tracks: found.tracks.map(Self.track))
    }

    // MARK: - Favourites

    private static var favouritesFile: URL { Storage.supportDirectory.appendingPathComponent("library-favourites.json") }

    /// Artists and albums of the catalog, and tracks when they are in the library.
    func isFavourite(_ item: LibraryItem) -> Bool? {
        switch item {
        case .artist(let artist): favourites.artists.contains(artist.id)
        case .album(let album): favourites.albums.contains(album.id)
        case .playlist: nil
        case .track(let info): catalog.contains(info.url) ? favourites.tracks.contains(info.url.path) : nil
        }
    }

    func setFavourite(_ items: [LibraryItem], _ favourite: Bool) -> Task<Void, Error> {
        func mark(_ ids: inout Set<String>, _ id: String) {
            if favourite { ids.insert(id) } else { ids.remove(id) }
        }
        var changed = favourites
        for item in items where isFavourite(item) != nil {
            switch item {
            case .artist(let artist): mark(&changed.artists, artist.id)
            case .album(let album): mark(&changed.albums, album.id)
            case .playlist: break
            case .track(let info): mark(&changed.tracks, info.url.path)
            }
        }
        do {
            try JSONEncoder().encode(changed).write(to: Self.favouritesFile, options: .atomic)
            favourites = changed
            return Task {}
        } catch {
            return Task { throw error }
        }
    }

    // MARK: - Playlists

    /// Playlist files in the app's folder (.m3u8 when made here); the id is the path.
    static var playlistFolder: URL { Storage.supportDirectory.appendingPathComponent("Playlists", isDirectory: true) }

    var editsPlaylists: Bool { true }

    /// Read from the folder each time: it is small, and files may come and go there.
    var editablePlaylists: [LibraryPlaylist] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.playlistFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter(PlaylistFile.isPlaylist).map { file in
            let tracks = (try? PlaylistFile.read(file)) ?? []
            return LibraryPlaylist(
                id: file.path, name: file.deletingPathExtension().lastPathComponent, trackCount: tracks.count,
                duration: Int(tracks.compactMap(\.duration).reduce(0, +).rounded()))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func canAddToPlaylist(_ track: TrackInfo) -> Bool {
        catalog.contains(track.url)
    }

    func createPlaylist(named name: String, with tracks: [TrackInfo]) async throws {
        // A name is a file name: no slashes or colons, not hidden.
        var fileName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if fileName.hasPrefix(".") { fileName = "_" + fileName.dropFirst() }
        let file = Self.playlistFolder.appendingPathComponent(fileName).appendingPathExtension("m3u8")
        guard !editablePlaylists.contains(where: { $0.name.localizedCaseInsensitiveCompare(fileName) == .orderedSame }) else {
            throw LibraryError("There is a playlist named “\(fileName)” already.")
        }
        try FileManager.default.createDirectory(at: Self.playlistFolder, withIntermediateDirectories: true)
        try write([], adding: tracks, to: file)
    }

    func add(_ tracks: [TrackInfo], to playlist: LibraryPlaylist) async throws {
        let file = URL(fileURLWithPath: playlist.id)
        try write(PlaylistFile.read(file), adding: tracks, to: file)
    }

    /// Into the Trash, where it can be taken back from.
    func deletePlaylist(_ playlist: LibraryPlaylist) async throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: playlist.id), resultingItemURL: nil)
    }

    /// The library's tracks among `tracks` go after `entries`, with their tags.
    private func write(_ entries: [TrackInfo], adding tracks: [TrackInfo], to file: URL) throws {
        let added = tracks.compactMap { catalog.entry(at: $0.url).map(Self.track)?.info }
        let format: PlaylistFile.Format = file.pathExtension.lowercased() == "pls" ? .pls : .m3u8
        try PlaylistFile.data(for: entries + added, format: format, base: file.deletingLastPathComponent()).write(to: file, options: .atomic)
    }

    private static func artist(_ artist: LibraryCatalog.Artist) -> LibraryArtist {
        LibraryArtist(id: artist.id, name: artist.name, albumCount: artist.albumCount)
    }

    private static func album(_ album: LibraryCatalog.Album) -> LibraryAlbum {
        LibraryAlbum(id: album.id, name: album.name, artist: album.artist, year: album.year)
    }

    private static func track(_ entry: LibraryEntry) -> LibraryTrack {
        var info = entry.info
        if info.title == nil { info.title = entry.displayTitle }
        return LibraryTrack(info: info, number: entry.trackNumber)
    }
}
