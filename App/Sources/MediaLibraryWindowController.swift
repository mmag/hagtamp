import AppKit
import ClassicUI
import NavidromeKit
import PlayerCore
import SkinKit

/// The media library: Navidrome browsing in a skinned generic window,
/// modelled on Winamp 5's "Audio" view (artist and album filters above the
/// track list).
@MainActor
final class MediaLibraryWindowController: SkinWindowController {
    enum View: Int, CaseIterable {
        case library, recent, playlists

        var title: String {
            switch self {
            case .library: "Library"
            case .recent: "Recently Added"
            case .playlists: "Playlists"
            }
        }
    }

    /// Keyboard focus inside the window.
    enum Focus: Equatable {
        case sidebar, search, upper(Int), tracks
    }

    private var widthSteps = 11
    private var heightSteps = 10
    private var view = View.library
    private var focus = Focus.tracks
    private var search = ""
    private var searchResults: NavidromeSearchResult?

    private var artists: [NavidromeArtist] = []
    private var albums: [NavidromeAlbum] = []
    private var playlists: [NavidromePlaylist] = []
    private var songs: [NavidromeSong] = []
    /// Per list: selection and scroll (0-1 = upper lists, 2 = tracks).
    private var selection: [Int: Set<Int>] = [:]
    private var scroll: [Int: Int] = [:]
    private var anchor: [Int: Int] = [:]
    private var loading: [Int: String] = [:]
    private var status = ""
    private var pressedButton: MediaLibraryButton?
    private var loadedServer: String?
    /// Play the tracks as soon as they arrive (double-click on an artist/album/playlist).
    private var playWhenLoaded = false
    private var thumbDrag: (list: Int, offset: Int)?
    private var loadGeneration = 0

    private static let tracksList = 2

    init(manager: WindowManager) {
        super.init(id: .mediaLibrary, manager: manager)
    }

    private var navidrome: NavidromeService { manager.navidrome }
    private var width: Int { GenWindowRenderer.baseWidth + widthSteps * 25 }
    private var height: Int { GenWindowRenderer.baseHeight + heightSteps * 29 }
    private var upperCount: Int { view == .library ? 2 : 1 }
    private var layout: MediaLibraryLayout {
        MediaLibraryLayout(width: width, height: height, upperCount: upperCount, showsPreferencesButton: !navidrome.isConfigured)
    }

    override func regions() -> [ControlRegion] {
        let content = GenWindowRenderer.contentRect(width: width, height: height)
        return GenWindowLayout.regions(width: width, height: height)
            + [ControlRegion(.trackList, content, .press, cursor: .normal)]
    }
    override func pixelSize() -> (width: Int, height: Int) { (width, height) }
    override func titleBarDoubleClicked() {}

    // MARK: - State

    override func renderBitmap() -> Bitmap {
        reloadIfServerChanged()
        return MediaLibraryRenderer.render(manager.skin, state())
    }

    private func state() -> MediaLibraryState {
        var frame = GenWindowState(title: "Media Library")
        frame.focused = isFocused
        frame.pressed = pressed
        frame.widthSteps = widthSteps
        frame.heightSteps = heightSteps

        var sidebar = ListViewModel(columns: [ListColumn("")], rows: View.allCases.map { [$0.title] })
        sidebar.showsHeader = false
        sidebar.showsScrollbar = false
        sidebar.selection = [view.rawValue]
        sidebar.focused = focus == .sidebar && isFocused

        var state = MediaLibraryState(frame: frame, sidebar: sidebar, upper: upperModels(), tracks: model(for: Self.tracksList))
        state.search = search
        state.searchFocused = focus == .search && isFocused
        state.caretVisible = Int(Date().timeIntervalSince1970 * 2) % 2 == 0
        state.status = statusText
        state.pressedButton = pressedButton
        state.showsPreferencesButton = !navidrome.isConfigured
        return state
    }

    private func upperModels() -> [ListViewModel] {
        (0..<upperCount).map { model(for: $0) }
    }

    private func columns(for list: Int) -> [ListColumn] {
        switch (view, list) {
        case (.library, 0): [ListColumn("Artist"), ListColumn("Albums", width: 40, alignRight: true)]
        case (.library, 1), (.recent, 0): [ListColumn("Album"), ListColumn("Artist"), ListColumn("Year", width: 34, alignRight: true)]
        case (.playlists, 0): [ListColumn("Playlist"), ListColumn("Tracks", width: 40, alignRight: true), ListColumn("Length", width: 44, alignRight: true)]
        default:
            [
                ListColumn("#", width: 22, alignRight: true), ListColumn("Title"), ListColumn("Artist"), ListColumn("Album"),
                ListColumn("Length", width: 40, alignRight: true),
            ]
        }
    }

    private func rows(for list: Int) -> [[String]] {
        func time(_ seconds: Int?) -> String { seconds.map { Marquee.timeString($0) } ?? "" }
        switch (view, list) {
        case (.library, 0): return artists.map { [$0.name, $0.albumCount.map(String.init) ?? ""] }
        case (.library, 1), (.recent, 0): return albums.map { [$0.name, $0.artist ?? "", $0.year.map(String.init) ?? ""] }
        case (.playlists, 0): return playlists.map { [$0.name, $0.songCount.map(String.init) ?? "", time($0.duration)] }
        default: return songs.map { [$0.track.map(String.init) ?? "", $0.title, $0.artist ?? "", $0.album ?? "", time($0.duration)] }
        }
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
        if !navidrome.isConfigured { return "Navidrome is not set up." }
        if !status.isEmpty { return status }
        let seconds = songs.compactMap(\.duration).reduce(0, +)
        return songs.isEmpty ? "" : "\(songs.count) tracks, \(Marquee.timeString(seconds))"
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

    private func reloadIfServerChanged() {
        let key = navidrome.isConfigured ? navidrome.server?.key : nil
        guard key != loadedServer else { return }
        loadedServer = key
        artists = []
        albums = []
        playlists = []
        songs = []
        selection = [:]
        scroll = [:]
        if key != nil { loadView() }
    }

    /// Runs `work` and applies its result unless the view changed meanwhile.
    private func load<T: Sendable>(
        into list: Int, _ work: @escaping @Sendable (NavidromeClient) async throws -> T, apply: @escaping (T) -> Void
    ) {
        guard let client = navidrome.client else { return }
        let generation = loadGeneration
        loading[list] = "Loading…"
        changed()
        Task {
            do {
                let result = try await work(client)
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
        artists = []
        albums = []
        playlists = []
        songs = []
        selection = [:]
        scroll = [:]
        status = ""
        switch view {
        case .library:
            if let results = searchResults {
                artists = results.artist ?? []
                albums = results.album ?? []
                // Found songs come by relevance; list them album by album.
                songs = (results.song ?? []).sorted {
                    ($0.album ?? "", $0.discNumber ?? 0, $0.track ?? 0) < ($1.album ?? "", $1.discNumber ?? 0, $1.track ?? 0)
                }
            } else {
                load(into: 0, { try await $0.artists() }) { [weak self] in self?.artists = $0 }
            }
        case .recent:
            load(into: 0, { try await $0.albumList(.newest, size: 200) }) { [weak self] in self?.albums = $0 }
        case .playlists:
            load(into: 0, { try await $0.playlists() }) { [weak self] in self?.playlists = $0 }
        }
        changed()
    }

    /// A row of an upper list was selected: load what it contains.
    private func selected(row: Int, in list: Int) {
        loadGeneration += 1
        let tracks = Self.tracksList
        songs = []
        selection[tracks] = []
        scroll[tracks] = 0
        switch (view, list) {
        case (.library, 0):
            guard artists.indices.contains(row) else { return }
            let id = artists[row].id
            albums = []
            selection[1] = []
            scroll[1] = 0
            load(into: 1, { try await $0.albums(ofArtist: id) }) { [weak self] albums in
                self?.albums = albums
                self?.loadSongs(of: albums)
            }
        case (.library, 1), (.recent, 0):
            guard albums.indices.contains(row) else { return }
            loadSongs(of: [albums[row]])
        case (.playlists, 0):
            guard playlists.indices.contains(row) else { return }
            let id = playlists[row].id
            load(into: tracks, { try await $0.playlist(id).entry ?? [] }) { [weak self] songs in self?.showSongs(songs) }
        default:
            break
        }
    }

    private func loadSongs(of albums: [NavidromeAlbum]) {
        let ids = albums.map(\.id)
        load(into: Self.tracksList, { client in
            try await withThrowingTaskGroup(of: (Int, [NavidromeSong]).self) { group in
                for (i, id) in ids.enumerated() {
                    group.addTask { (i, try await client.album(id).song ?? []) }
                }
                var parts: [(Int, [NavidromeSong])] = []
                for try await part in group { parts.append(part) }
                return parts.sorted { $0.0 < $1.0 }.flatMap(\.1)
            }
        }) { [weak self] songs in self?.showSongs(songs) }
    }

    private func showSongs(_ songs: [NavidromeSong]) {
        self.songs = songs
        if playWhenLoaded {
            playWhenLoaded = false
            play(songs, startingAt: 0)
        }
    }

    private func runSearch() {
        let query = search.trimmingCharacters(in: .whitespaces)
        view = .library
        guard !query.isEmpty else {
            searchResults = nil
            loadView()
            return
        }
        loadGeneration += 1
        load(into: Self.tracksList, { try await $0.search(query) }) { [weak self] results in
            self?.searchResults = results
            self?.loadView()
        }
    }

    // MARK: - Playing

    private func play(_ songs: [NavidromeSong], startingAt index: Int) {
        guard !songs.isEmpty else { return }
        manager.model.load(tracks: songs.map(NavidromeTrack.info(for:)), play: false)
        manager.model.play(trackAt: min(index, songs.count - 1))
    }

    /// The selected tracks, or all of them when none are selected.
    private var chosenSongs: [NavidromeSong] {
        let chosen = (selection[Self.tracksList] ?? []).sorted().filter(songs.indices.contains).map { songs[$0] }
        return chosen.isEmpty ? songs : chosen
    }

    private func perform(_ button: MediaLibraryButton) {
        switch button {
        case .play: play(chosenSongs, startingAt: 0)
        case .enqueue: manager.model.add(tracks: chosenSongs.map(NavidromeTrack.info(for:)))
        case .clearSearch:
            search = ""
            runSearch()
        case .preferences:
            (NSApp.delegate as? AppDelegate)?.showPreferences(nil)
        }
    }

    // MARK: - Pointer

    override func buttonClicked(_ control: Control) {
        if control == .close { manager.setVisible(.mediaLibrary, false) }
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
            // Clicking the current view again also leaves search results.
            if let chosen = View(rawValue: row), chosen != view || searchResults != nil {
                view = chosen
                searchResults = nil
                search = ""
                loadView()
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
                play(songs, startingAt: row)
            } else if wasSelected && loading[Self.tracksList] == nil && loading[1] == nil {
                play(songs, startingAt: 0)
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
            if list == Self.tracksList { play(songs, startingAt: max(0, current)) } else { play(songs, startingAt: 0) }
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

    override func contextMenuRequested(at point: SkinPoint, event: NSEvent) {
        manager.showMainMenu(for: event, in: window.skinView)
    }

    /// For the self test.
    var summary: String {
        "view=\(view.title) artists=\(artists.count) albums=\(albums.count) playlists=\(playlists.count) songs=\(songs.count) status=\(statusText)"
    }

    func selectForTesting(row: Int, in list: Int) {
        selection[list] = [row]
        selected(row: row, in: list)
    }

    func playAllForTesting() { perform(.play) }
}
