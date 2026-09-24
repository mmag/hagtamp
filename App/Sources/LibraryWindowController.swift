import AppKit
import ClassicUI
import PlayerCore
import SkinKit

/// A library in a skinned generic window, modelled on Winamp 5's media
/// library "Audio" view: views in a sidebar, artist and album lists above
/// the track list, search. Navidrome and the local files each get one.
@MainActor
final class LibraryWindowController: SkinWindowController {
    /// Keyboard focus inside the window.
    enum Focus: Equatable {
        case sidebar, search, upper(Int), tracks
    }

    let source: LibrarySource
    private var widthSteps = 11
    private var heightSteps = 10
    private var viewIndex = 0
    private var focus = Focus.tracks
    private var search = ""
    private var searchResults: LibraryContent?

    private var artists: [LibraryArtist] = []
    private var albums: [LibraryAlbum] = []
    private var playlists: [LibraryPlaylist] = []
    private var tracks: [LibraryTrack] = []
    /// Per list: selection and scroll (0-1 = upper lists, 2 = tracks).
    private var selection: [Int: Set<Int>] = [:]
    private var scroll: [Int: Int] = [:]
    private var anchor: [Int: Int] = [:]
    private var loading: [Int: String] = [:]
    private var status = ""
    private var pressedButton: MediaLibraryButton?
    private var loadedRevision: String?
    /// Play the tracks as soon as they arrive (double-click on an artist/album/playlist).
    private var playWhenLoaded = false
    private var thumbDrag: (list: Int, offset: Int)?
    private var loadGeneration = 0

    private static let tracksList = 2

    init(id: WindowID, source: LibrarySource, manager: WindowManager) {
        self.source = source
        super.init(id: id, manager: manager)
        source.onChange = { [weak self] in
            guard let self, self.window.isVisible else { return }
            self.changed()
        }
    }

    private var view: LibraryView { source.views[viewIndex] }
    private var width: Int { GenWindowRenderer.baseWidth + widthSteps * 25 }
    private var height: Int { GenWindowRenderer.baseHeight + heightSteps * 29 }
    private var upperCount: Int {
        switch view.lists {
        case .artistsAndAlbums: 2
        case .stations: 0
        case .albums, .playlists: 1
        }
    }
    private var layout: MediaLibraryLayout {
        MediaLibraryLayout(width: width, height: height, upperCount: upperCount, showsSetupButton: source.revision == nil)
    }

    override func regions() -> [ControlRegion] {
        let content = GenWindowRenderer.contentRect(width: width, height: height)
        return GenWindowLayout.regions(width: width, height: height)
            + [ControlRegion(.trackList, content, .press, cursor: .normal)]
    }
    override func pixelSize() -> (width: Int, height: Int) { (width, height) }
    override func titleBarDoubleClicked() {}

    override func savedState() -> [String: Int] { ["width": widthSteps, "height": heightSteps, "view": viewIndex] }

    override func restore(_ state: [String: Int]) {
        widthSteps = max(7, state["width"] ?? widthSteps)
        heightSteps = max(6, state["height"] ?? heightSteps)
        viewIndex = min(max(0, state["view"] ?? 0), source.views.count - 1)
    }

    // MARK: - State

    override func renderBitmap() -> Bitmap {
        reloadIfLibraryChanged()
        return MediaLibraryRenderer.render(manager.skin, state())
    }

    private func state() -> MediaLibraryState {
        var frame = GenWindowState(title: source.windowTitle)
        frame.focused = isFocused
        frame.pressed = pressed
        frame.widthSteps = widthSteps
        frame.heightSteps = heightSteps

        var sidebar = ListViewModel(columns: [ListColumn("")], rows: source.views.map { [$0.title] })
        sidebar.showsHeader = false
        sidebar.showsScrollbar = false
        sidebar.selection = [viewIndex]
        sidebar.focused = focus == .sidebar && isFocused

        var state = MediaLibraryState(frame: frame, sidebar: sidebar, upper: upperModels(), tracks: model(for: Self.tracksList))
        state.search = search
        state.searchFocused = focus == .search && isFocused
        state.caretVisible = Int(Date().timeIntervalSince1970 * 2) % 2 == 0
        state.status = statusText
        state.pressedButton = pressedButton
        state.setupButton = source.revision == nil ? source.setupTitle : nil
        return state
    }

    private func upperModels() -> [ListViewModel] {
        (0..<upperCount).map { model(for: $0) }
    }

    private enum ListKind { case artists, albums, playlists, tracks, stations }

    private func kind(of list: Int) -> ListKind {
        switch (view.lists, list) {
        case (.stations, Self.tracksList): .stations
        case (_, Self.tracksList): .tracks
        case (.artistsAndAlbums, 0): .artists
        case (.playlists, 0): .playlists
        default: .albums
        }
    }

    private func columns(for list: Int) -> [ListColumn] {
        switch kind(of: list) {
        case .artists: [ListColumn("Artist"), ListColumn("Albums", width: 40, alignRight: true)]
        case .albums: [ListColumn("Album"), ListColumn("Artist"), ListColumn("Year", width: 34, alignRight: true)]
        case .playlists: [ListColumn("Playlist"), ListColumn("Tracks", width: 40, alignRight: true), ListColumn("Length", width: 44, alignRight: true)]
        case .stations: [ListColumn("Station"), ListColumn("Stream")]
        case .tracks:
            [
                ListColumn("#", width: 22, alignRight: true), ListColumn("Title"), ListColumn("Artist"), ListColumn("Album"),
                ListColumn("Length", width: 40, alignRight: true),
            ]
        }
    }

    private func rows(for list: Int) -> [[String]] {
        func time(_ seconds: Int?) -> String { seconds.map { Marquee.timeString($0) } ?? "" }
        switch kind(of: list) {
        case .artists: return artists.map { [$0.name, $0.albumCount.map(String.init) ?? ""] }
        case .albums: return albums.map { [offlineMark(.album($0)) + $0.name, $0.artist ?? "", $0.year.map(String.init) ?? ""] }
        case .playlists: return playlists.map { [offlineMark(.playlist($0)) + $0.name, $0.trackCount.map(String.init) ?? "", time($0.duration)] }
        case .stations: return tracks.map { [$0.info.title ?? "", $0.info.url.absoluteString] }
        case .tracks:
            return tracks.map {
                [
                    $0.number.map(String.init) ?? "", $0.info.title ?? $0.info.displayName, $0.info.artist ?? "", $0.info.album ?? "",
                    time($0.info.duration.map { Int($0.rounded()) }),
                ]
            }
        }
    }

    /// Albums and playlists kept offline are marked with a dot.
    private func offlineMark(_ item: LibraryItem) -> String {
        source.isKeptOffline(item) == true ? "● " : ""
    }

    private func model(for list: Int) -> ListViewModel {
        var model = ListViewModel(columns: columns(for: list), rows: rows(for: list))
        model.selection = selection[list] ?? []
        model.firstVisibleRow = scroll[list] ?? 0
        model.focused = isFocused && (list == Self.tracksList ? focus == .tracks : focus == .upper(list))
        model.placeholder = loading[list]
        return model
    }

    private var statusText: String {
        if source.revision == nil { return source.unavailableText }
        if let activity = source.activity { return activity }
        if !status.isEmpty { return status }
        if view.lists == .stations { return tracks.isEmpty ? "" : "\(tracks.count) \(tracks.count == 1 ? "station" : "stations")" }
        let seconds = tracks.compactMap(\.info.duration).reduce(0, +)
        return tracks.isEmpty ? "" : "\(tracks.count) \(tracks.count == 1 ? "track" : "tracks"), \(Marquee.timeString(Int(seconds.rounded())))"
    }

    private func listRect(_ list: Int) -> PixelRect {
        list == Self.tracksList ? layout.tracks : layout.upper[list]
    }

    private func geometry(_ list: Int) -> GenControls.ListGeometry {
        GenControls.listGeometry(listRect(list), showsHeader: true)
    }

    private func changed() {
        manager.render()
    }

    // MARK: - Loading

    /// Another server, a rescanned folder: start over in the current view.
    private func reloadIfLibraryChanged() {
        let revision = source.revision
        guard revision != loadedRevision else { return }
        loadedRevision = revision
        searchResults = nil
        search = ""
        if revision != nil {
            loadView()
        } else {
            clearLists()
        }
    }

    private func clearLists() {
        artists = []
        albums = []
        playlists = []
        tracks = []
        selection = [:]
        scroll = [:]
    }

    /// Runs `work` and applies its result unless the view changed meanwhile.
    private func load<T>(into list: Int, _ work: @escaping @MainActor () async throws -> T, apply: @escaping (T) -> Void) {
        let generation = loadGeneration
        loading[list] = "Loading…"
        changed()
        Task {
            do {
                let result = try await work()
                guard generation == loadGeneration else { return }
                loading[list] = nil
                status = ""
                apply(result)
            } catch {
                guard generation == loadGeneration else { return }
                loading[list] = nil
                status = error.localizedDescription
            }
            changed()
        }
    }

    private func loadView() {
        loadGeneration += 1
        clearLists()
        status = ""
        loading = [:]
        if viewIndex == 0, let results = searchResults {
            show(results)
        } else {
            let source = self.source, index = viewIndex
            load(into: upperCount == 0 ? Self.tracksList : 0, { try await source.content(ofView: index) }) { [weak self] in self?.show($0) }
        }
        changed()
    }

    private func show(_ content: LibraryContent) {
        artists = content.artists
        albums = content.albums
        playlists = content.playlists
        showTracks(content.tracks)
    }

    /// A row of an upper list was selected: load what it contains.
    private func selected(row: Int, in list: Int) {
        loadGeneration += 1
        let source = self.source
        tracks = []
        selection[Self.tracksList] = []
        scroll[Self.tracksList] = 0
        switch kind(of: list) {
        case .artists:
            guard artists.indices.contains(row) else { return }
            let artist = artists[row]
            albums = []
            selection[1] = []
            scroll[1] = 0
            load(into: 1, { try await source.albums(of: artist) }) { [weak self] albums in
                self?.albums = albums
                self?.loadTracks(of: albums)
            }
        case .albums:
            guard albums.indices.contains(row) else { return }
            loadTracks(of: [albums[row]])
        case .playlists:
            guard playlists.indices.contains(row) else { return }
            let playlist = playlists[row]
            load(into: Self.tracksList, { try await source.tracks(of: playlist) }) { [weak self] in self?.showTracks($0) }
        case .tracks, .stations:
            break
        }
    }

    private func loadTracks(of albums: [LibraryAlbum]) {
        let source = self.source
        load(into: Self.tracksList, { try await source.tracks(of: albums) }) { [weak self] in self?.showTracks($0) }
    }

    private func showTracks(_ tracks: [LibraryTrack]) {
        self.tracks = tracks
        if playWhenLoaded {
            playWhenLoaded = false
            play(tracks, startingAt: 0)
        }
    }

    private func runSearch() {
        let query = search.trimmingCharacters(in: .whitespaces)
        viewIndex = 0
        guard !query.isEmpty else {
            searchResults = nil
            loadView()
            return
        }
        loadGeneration += 1
        let source = self.source
        load(into: Self.tracksList, { try await source.search(query) }) { [weak self] results in
            self?.searchResults = results
            self?.loadView()
        }
    }

    // MARK: - Playing

    private func play(_ tracks: [LibraryTrack], startingAt index: Int) {
        guard !tracks.isEmpty else { return }
        manager.model.load(tracks: tracks.map(\.info), play: false, tagsKnown: source.tracksHaveTags)
        manager.model.play(trackAt: min(index, tracks.count - 1))
    }

    /// The selected tracks, or all of them when none are selected.
    private var chosenTracks: [LibraryTrack] {
        let chosen = (selection[Self.tracksList] ?? []).sorted().filter(tracks.indices.contains).map { tracks[$0] }
        return chosen.isEmpty ? tracks : chosen
    }

    private func perform(_ button: MediaLibraryButton) {
        switch button {
        case .play: play(chosenTracks, startingAt: 0)
        case .enqueue: manager.model.add(tracks: chosenTracks.map(\.info), tagsKnown: source.tracksHaveTags)
        case .clearSearch:
            search = ""
            runSearch()
        case .setup:
            source.setUp()
        }
    }

    // MARK: - Pointer

    override func buttonClicked(_ control: Control) {
        if control == .close { manager.hideLibrary(self) }
    }

    private var resizeStart: (mouse: NSPoint, width: Int, height: Int)?

    override func pressBegan(_ control: Control, at point: SkinPoint, event: NSEvent) -> Bool {
        if control == .resize {
            resizeStart = (NSEvent.mouseLocation, widthSteps, heightSteps)
            return true
        }
        guard control == .trackList else { return false }
        let layout = self.layout
        if let button = layout.buttons.first(where: { $0.value.contains(x: point.x, y: point.y) })?.key {
            pressedButton = button
            changed()
            return true
        }
        if layout.searchField.contains(x: point.x, y: point.y) {
            focus = .search
            changed()
            return false
        }
        if layout.sidebar.contains(x: point.x, y: point.y) {
            focus = .sidebar
            let row = (point.y - layout.sidebar.y) / GenControls.rowHeight
            // Choosing the current view again leaves search results, or reloads it.
            if source.views.indices.contains(row), row != viewIndex || searchResults != nil || source.views[row].reloadsWhenChosenAgain {
                viewIndex = row
                searchResults = nil
                search = ""
                loadView()
                manager.saveLayout()
            }
            changed()
            return false
        }
        for list in (0..<upperCount) + [Self.tracksList] where listRect(list).contains(x: point.x, y: point.y) {
            return listPressed(list, at: point, event: event)
        }
        return false
    }

    private func listPressed(_ list: Int, at point: SkinPoint, event: NSEvent) -> Bool {
        focus = list == Self.tracksList ? .tracks : .upper(list)
        let g = geometry(list)
        let rowCount = rows(for: list).count
        let first = scroll[list] ?? 0
        if g.scrollbar.contains(x: point.x, y: point.y) {
            if g.scrollUp.contains(x: point.x, y: point.y) {
                scrollList(list, to: first - 1)
            } else if g.scrollDown.contains(x: point.x, y: point.y) {
                scrollList(list, to: first + 1)
            } else if let thumb = g.thumb(rowCount: rowCount, firstVisible: first) {
                if thumb.contains(x: point.x, y: point.y) {
                    thumbDrag = (list, point.y - thumb.y)
                    return true
                }
                scrollList(list, to: first + (point.y < thumb.y ? -g.visibleRows : g.visibleRows))
            }
            return false
        }
        guard let row = g.row(atY: point.y, firstVisible: first), row < rowCount else {
            changed()
            return false
        }
        let flags = event.modifierFlags
        var chosen = selection[list] ?? []
        if list == Self.tracksList && flags.contains(.shift), let from = anchor[list] {
            chosen = Set(min(from, row)...max(from, row))
        } else if list == Self.tracksList && flags.contains(.command) {
            if chosen.contains(row) { chosen.remove(row) } else { chosen.insert(row) }
            anchor[list] = row
        } else {
            chosen = [row]
            anchor[list] = row
        }
        let wasSelected = selection[list] == [row]
        selection[list] = chosen
        if event.clickCount == 2 {
            if list == Self.tracksList {
                play(tracks, startingAt: row)
            } else if wasSelected && loading[Self.tracksList] == nil && loading[1] == nil {
                play(tracks, startingAt: 0)
            } else {
                playWhenLoaded = true
            }
        } else if list != Self.tracksList && !wasSelected {
            selected(row: row, in: list)
        }
        changed()
        return false
    }

    override func pressDragged(_ control: Control, to point: SkinPoint, event: NSEvent) {
        if control == .resize, let start = resizeStart {
            let now = NSEvent.mouseLocation
            let scale = CGFloat(manager.scale)
            let dx = (now.x - start.mouse.x) / scale, dy = (start.mouse.y - now.y) / scale
            let newWidth = max(7, start.width + Int((dx / 25).rounded()))
            let newHeight = max(6, start.height + Int((dy / 29).rounded()))
            guard newWidth != widthSteps || newHeight != heightSteps else { return }
            widthSteps = newWidth
            heightSteps = newHeight
            manager.windowSizeChanged()
            return
        }
        if let drag = thumbDrag {
            let first = geometry(drag.list).firstVisible(forThumbAt: point.y - drag.offset, rowCount: rows(for: drag.list).count)
            scrollList(drag.list, to: first)
            return
        }
        if let button = pressedButton ?? layout.buttons.first(where: { $0.value.contains(x: point.x, y: point.y) })?.key {
            let inside = layout.buttons[button]?.contains(x: point.x, y: point.y) == true
            let shown: MediaLibraryButton? = inside ? button : nil
            if shown != pressedButton, pressedButton != nil || inside {
                pressedButton = shown
                changed()
            }
        }
    }

    override func pressEnded(_ control: Control, at point: SkinPoint, event: NSEvent) {
        resizeStart = nil
        thumbDrag = nil
        if let button = pressedButton {
            pressedButton = nil
            if layout.buttons[button]?.contains(x: point.x, y: point.y) == true { perform(button) }
            changed()
        }
    }

    private func scrollList(_ list: Int, to row: Int) {
        let maxFirst = max(0, rows(for: list).count - geometry(list).visibleRows)
        scroll[list] = min(maxFirst, max(0, row))
        changed()
    }

    override func scrolled(by delta: CGFloat) {
        let point = NSEvent.mouseLocation
        let frame = window.frame
        let scale = CGFloat(manager.scale)
        let x = Int((point.x - frame.minX) / scale), y = Int((frame.maxY - point.y) / scale)
        for list in (0..<upperCount) + [Self.tracksList] where listRect(list).contains(x: x, y: y) {
            scrollList(list, to: (scroll[list] ?? 0) - Int(delta.rounded()))
        }
    }

    // MARK: - Keyboard

    override func keyDown(_ event: NSEvent) -> Bool {
        if focus == .search { return searchKey(event) }
        let list: Int
        switch focus {
        case .tracks: list = Self.tracksList
        case .upper(let i): list = i
        default: return super.keyDown(event)
        }
        let rowCount = rows(for: list).count
        let current = (selection[list] ?? []).max() ?? -1
        func select(_ row: Int) {
            guard rowCount > 0 else { return }
            let row = min(max(0, row), rowCount - 1)
            selection[list] = [row]
            anchor[list] = row
            let g = geometry(list), first = scroll[list] ?? 0
            if row < first { scroll[list] = row } else if row >= first + g.visibleRows { scroll[list] = row - g.visibleRows + 1 }
            if list != Self.tracksList { selected(row: row, in: list) }
            changed()
        }
        switch event.keyCode {
        case 126: select(current - 1)
        case 125: select(current + 1)
        case 36, 76:
            if list == Self.tracksList { play(tracks, startingAt: max(0, current)) } else { play(tracks, startingAt: 0) }
        case 48:  // tab
            focus = .search
            changed()
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a", list == Self.tracksList {
                selection[list] = Set(0..<rowCount)
                changed()
                return true
            }
            return super.keyDown(event)
        }
        return true
    }

    private func searchKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76: runSearch()
        case 53:  // escape
            search = ""
            focus = .tracks
            runSearch()
        case 51: if !search.isEmpty { search.removeLast() }
        case 48: focus = .tracks
        default:
            guard !event.modifierFlags.contains(.command), let text = event.characters, text.allSatisfy({ !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 } }) else {
                return super.keyDown(event)
            }
            search += text
        }
        changed()
        return true
    }

    /// On an album, playlist or track: play, enqueue and (Navidrome) keep offline;
    /// elsewhere the main menu.
    override func contextMenuRequested(at point: SkinPoint, event: NSEvent) {
        guard let (list, row) = row(at: point) else {
            manager.showMainMenu(for: event, in: window.skinView)
            return
        }
        let menu = NSMenu()
        let source = self.source, model = manager.model
        switch kind(of: list) {
        case .albums, .playlists:
            let item: LibraryItem = kind(of: list) == .albums ? .album(albums[row]) : .playlist(playlists[row])
            menu.addItem(NSMenuItem(title: "Play") { [weak self] in
                Task { if let tracks = try? await source.tracks(of: item) { self?.play(tracks, startingAt: 0) } }
            })
            menu.addItem(NSMenuItem(title: "Enqueue") {
                Task {
                    if let tracks = try? await source.tracks(of: item) {
                        model.add(tracks: tracks.map(\.info), tagsKnown: source.tracksHaveTags)
                    }
                }
            })
            if let kept = source.isKeptOffline(item) {
                menu.addItem(.separator())
                menu.addItem(NSMenuItem(title: "Keep Offline", checked: kept) { source.setKeptOffline(item, !kept) })
            }
        case .tracks, .stations:
            if !(selection[list] ?? []).contains(row) {
                selection[list] = [row]
                changed()
            }
            menu.addItem(NSMenuItem(title: "Play") { [weak self] in
                guard let self else { return }
                self.play(self.chosenTracks, startingAt: 0)
            })
            menu.addItem(NSMenuItem(title: "Enqueue") { [weak self] in
                guard let self else { return }
                model.add(tracks: self.chosenTracks.map(\.info), tagsKnown: source.tracksHaveTags)
            })
        case .artists:
            manager.showMainMenu(for: event, in: window.skinView)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: window.skinView)
    }

    /// The list and row under a point.
    private func row(at point: SkinPoint) -> (list: Int, row: Int)? {
        for list in (0..<upperCount) + [Self.tracksList] where listRect(list).contains(x: point.x, y: point.y) {
            guard let row = geometry(list).row(atY: point.y, firstVisible: scroll[list] ?? 0), row < rows(for: list).count else { return nil }
            return (list, row)
        }
        return nil
    }

    /// Self test: what a right click on a row offers.
    func contextMenuTitlesForTesting(list: Int, row: Int) -> [String] {
        guard kind(of: list) == .albums || kind(of: list) == .playlists else { return [] }
        let item: LibraryItem = kind(of: list) == .albums ? .album(albums[row]) : .playlist(playlists[row])
        return ["Play", "Enqueue"] + (source.isKeptOffline(item).map { ["Keep Offline" + ($0 ? " ✓" : "")] } ?? [])
    }

    func setKeptOfflineForTesting(list: Int, row: Int, _ keep: Bool) {
        let item: LibraryItem = kind(of: list) == .albums ? .album(albums[row]) : .playlist(playlists[row])
        source.setKeptOffline(item, keep)
    }

    /// For the self test.
    var summary: String {
        "view=\(view.title) artists=\(artists.count) albums=\(albums.count) playlists=\(playlists.count) songs=\(tracks.count) status=\(statusText)"
    }

    func selectForTesting(row: Int, in list: Int) {
        selection[list] = [row]
        selected(row: row, in: list)
    }

    func playAllForTesting() { perform(.play) }

    func searchForTesting(_ query: String) {
        search = query
        runSearch()
    }

    func chooseViewForTesting(_ index: Int) {
        guard index != viewIndex else { return }
        viewIndex = index
        searchResults = nil
        loadView()
    }
}
