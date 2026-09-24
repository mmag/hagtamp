import AppKit
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
        watcher = FolderWatcher(folders) { Task { await library.rescan() } }
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
        [LibraryView(title: "Audio", lists: .artistsAndAlbums), LibraryView(title: "Recently Added", lists: .albums)]
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
        index == 0 ? LibraryContent(artists: catalog.artists.map(Self.artist)) : LibraryContent(albums: catalog.recentlyAdded.map(Self.album))
    }

    func albums(of artist: LibraryArtist) async throws -> [LibraryAlbum] {
        catalog.albums(ofArtist: artist.id).map(Self.album)
    }

    func tracks(of albums: [LibraryAlbum]) async throws -> [LibraryTrack] {
        albums.flatMap { catalog.tracks(ofAlbum: $0.id) }.map(Self.track)
    }

    func tracks(of playlist: LibraryPlaylist) async throws -> [LibraryTrack] { [] }

    func search(_ query: String) async throws -> LibraryContent {
        let found = catalog.search(query)
        return LibraryContent(artists: found.artists.map(Self.artist), albums: found.albums.map(Self.album), tracks: found.tracks.map(Self.track))
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
