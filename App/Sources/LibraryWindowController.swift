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

    /// The lists as loaded; the four below show them in their sort order.
    private var loaded = LibraryContent() {
        didSet { sortLists() }
    }
    private var artists: [LibraryArtist] = []
    private var albums: [LibraryAlbum] = []
    private var playlists: [LibraryPlaylist] = []
    private var tracks: [LibraryTrack] = []
    /// Per kind of list: the loaded index of each row shown.
    private var orders: [ListKind: [Int]] = [:]
    /// Per view and list ("<view>.<list>"); unsorted lists keep the order they came in.
    private var sorts: [String: ListSort] = [:]
    /// Per kind of list, as its dividers were dragged: fixed widths and flexible weights.
    private var columnSizes: [ListKind: [Int]] = [:]
    private var columnDrag: (list: Int, divider: Int, columns: [ListColumn], x: Int)?
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
        MediaLibraryLayout(
            width: width, height: height, upperCount: upperCount, showsSetupButton: source.revision == nil, textSize: manager.textSize)
    }

    override func regions() -> [ControlRegion] {
        let content = GenWindowRenderer.contentRect(width: width, height: height)
        return GenWindowLayout.regions(width: width, height: height)
            + [ControlRegion(.trackList, content, .press, cursor: .normal)]
    }
    override func pixelSize() -> (width: Int, height: Int) { (width, height) }
    override func titleBarDoubleClicked() {}

    /// Sorts as "sort.<view>.<list>" = ±(column + 1), column sizes as "columns.<kind>.<column>".
    override func savedState() -> [String: Int] {
        var state = ["width": widthSteps, "height": heightSteps, "view": viewIndex]
        for (id, sort) in sorts { state["sort.\(id)"] = (sort.column + 1) * (sort.ascending ? 1 : -1) }
        for (kind, sizes) in columnSizes {
            for (column, size) in sizes.enumerated() { state["columns.\(kind.rawValue).\(column)"] = size }
        }
        return state
    }

    override func restore(_ state: [String: Int]) {
        widthSteps = max(7, state["width"] ?? widthSteps)
        heightSteps = max(6, state["height"] ?? heightSteps)
        viewIndex = min(max(0, state["view"] ?? 0), source.views.count - 1)
        var sizes: [ListKind: [Int: Int]] = [:]
        for (key, value) in state {
            let parts = key.split(separator: ".").map(String.init)
            guard parts.count == 3 else { continue }
            if parts[0] == "sort", value != 0 {
                sorts["\(parts[1]).\(parts[2])"] = ListSort(column: abs(value) - 1, ascending: value > 0)
            } else if parts[0] == "columns", let kind = ListKind(rawValue: parts[1]), let column = Int(parts[2]), value > 0 {
                sizes[kind, default: [:]][column] = value
            }
        }
        columnSizes = sizes.mapValues { sizes in (0..<sizes.count).compactMap { sizes[$0] } }
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
        sidebar.textSize = manager.textSize
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

    private enum ListKind: String { case artists, albums, playlists, tracks, stations }

    private func kind(of list: Int) -> ListKind {
        switch (view.lists, list) {
        case (.stations, Self.tracksList): .stations
        case (_, Self.tracksList): .tracks
        case (.artistsAndAlbums, 0): .artists
        case (.playlists, 0): .playlists
        default: .albums
        }
    }

    /// The list showing a kind in this view.
    private func list(showing kind: ListKind) -> Int? {
        ((0..<upperCount) + [Self.tracksList]).first { self.kind(of: $0) == kind }
    }

    /// A kind's columns, sized as their dividers were dragged.
    private func columns(for list: Int) -> [ListColumn] {
        let kind = kind(of: list)
        var columns = Self.columns(kind)
        if let sizes = columnSizes[kind], sizes.count == columns.count {
            for i in columns.indices {
                if columns[i].width != nil { columns[i].width = sizes[i] } else { columns[i].weight = sizes[i] }
            }
        }
        return columns
    }

    private static func columns(_ kind: ListKind) -> [ListColumn] {
        switch kind {
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

    /// What a column sorts by: numbers as numbers, text the way Finder sorts
    /// names; missing values first.
    private enum SortKey {
        case number(Double?)
        case text(String)

        static func number(_ value: Int?) -> SortKey { .number(value.map(Double.init)) }

        func compare(_ other: SortKey) -> ComparisonResult {
            switch (self, other) {
            case (.number(let a), .number(let b)):
                let a = a ?? -.infinity, b = b ?? -.infinity
                return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
            case (.text(let a), .text(let b)):
                return a.localizedStandardCompare(b)
            default:
                return .orderedSame
            }
        }
    }

    /// Shows the loaded lists in their sort order; each kind's keys follow its columns.
    private func sortLists() {
        func sorted<T>(_ items: [T], _ kind: ListKind, _ keys: [(T) -> SortKey]) -> [T] {
            var order = Array(items.indices)
            if let list = list(showing: kind), let sort = sorts[sortID(list)], keys.indices.contains(sort.column) {
                let values = items.map(keys[sort.column])
                // Ties keep the loaded order (an artist's tracks stay in album order).
                order.sort { a, b in
                    switch values[a].compare(values[b]) {
                    case .orderedSame: a < b
                    case .orderedAscending: sort.ascending
                    case .orderedDescending: !sort.ascending
                    }
                }
            }
            orders[kind] = order
            return order.map { items[$0] }
        }
        artists = sorted(loaded.artists, .artists, [{ .text($0.name) }, { .number($0.albumCount) }])
        albums = sorted(loaded.albums, .albums, [{ .text($0.name) }, { .text($0.artist ?? "") }, { .number($0.year) }])
        playlists = sorted(loaded.playlists, .playlists, [{ .text($0.name) }, { .number($0.trackCount) }, { .number($0.duration) }])
        tracks =
            view.lists == .stations
            ? sorted(loaded.tracks, .stations, [{ .text($0.info.title ?? "") }, { .text($0.info.url.absoluteString) }])
            : sorted(
                loaded.tracks, .tracks,
                [
                    { .number($0.number) }, { .text($0.info.title ?? $0.info.displayName) }, { .text($0.info.artist ?? "") },
                    { .text($0.info.album ?? "") }, { .number($0.info.duration) },
                ])
    }

    private func sortID(_ list: Int) -> String { "\(viewIndex).\(list)" }

    /// A header was clicked: sorted ascending, then descending, then as loaded.
    /// Selected rows stay selected.
    private func sortByColumn(_ column: Int, in list: Int) {
        let id = sortID(list), kind = kind(of: list)
        switch sorts[id] {
        case let sort? where sort.column == column && sort.ascending: sorts[id] = ListSort(column: column, ascending: false)
        case let sort? where sort.column == column: sorts[id] = nil
        default: sorts[id] = ListSort(column: column, ascending: true)
        }
        let before = orders[kind] ?? []
        sortLists()
        var row: [Int: Int] = [:]
        for (shown, index) in (orders[kind] ?? []).enumerated() { row[index] = shown }
        func moved(_ old: Int) -> Int? { before.indices.contains(old) ? row[before[old]] : nil }
        selection[list] = Set((selection[list] ?? []).compactMap(moved))
        anchor[list] = anchor[list].flatMap(moved)
        manager.saveLayout()
        changed()
    }

    /// Albums and playlists kept offline are marked with a dot.
    private func offlineMark(_ item: LibraryItem) -> String {
        source.isKeptOffline(item) == true ? "● " : ""
    }

    private func model(for list: Int) -> ListViewModel {
        var model = ListViewModel(columns: columns(for: list), rows: rows(for: list))
        model.selection = selection[list] ?? []
        model.sort = sorts[sortID(list)]
        model.firstVisibleRow = scroll[list] ?? 0
        model.focused = isFocused && (list == Self.tracksList ? focus == .tracks : focus == .upper(list))
        model.placeholder = loading[list]
        model.textSize = manager.textSize
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
        GenControls.listGeometry(listRect(list), showsHeader: true, textSize: manager.textSize)
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
        loaded = LibraryContent()
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
        loaded = content
        playIfWaiting()
    }

    /// A row of an upper list was selected: load what it contains.
    private func selected(row: Int, in list: Int) {
        loadGeneration += 1
        let source = self.source
        loaded.tracks = []
        selection[Self.tracksList] = []
        scroll[Self.tracksList] = 0
        switch kind(of: list) {
        case .artists:
            guard artists.indices.contains(row) else { return }
            let artist = artists[row]
            loaded.albums = []
            selection[1] = []
            scroll[1] = 0
            load(into: 1, { try await source.albums(of: artist) }) { [weak self] albums in
                guard let self else { return }
                self.loaded.albums = albums
                self.loadTracks(of: self.albums)  // in the order shown
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
        loaded.tracks = tracks
        playIfWaiting()
    }

    private func playIfWaiting() {
        guard playWhenLoaded else { return }
        playWhenLoaded = false
        play(tracks, startingAt: 0)
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
            let row = (point.y - layout.sidebar.y) / manager.textSize.rowHeight
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
        if let header = g.header, header.contains(x: point.x, y: point.y) {
            return headerPressed(list, at: point, geometry: g)
        }
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

    /// A divider starts resizing its column; elsewhere the header sorts the list.
    private func headerPressed(_ list: Int, at point: SkinPoint, geometry g: GenControls.ListGeometry) -> Bool {
        let columns = columns(for: list)
        if let divider = g.divider(atX: point.x, y: point.y, columns, textSize: manager.textSize) {
            columnDrag = (list, divider, columns, point.x)
            return true
        }
        if let column = g.columnRanges(columns, textSize: manager.textSize).firstIndex(where: { $0.contains(point.x) }) {
            sortByColumn(column, in: list)
        }
        return false
    }

    override func systemCursor(at point: SkinPoint) -> NSCursor? {
        let onDivider = ((0..<upperCount) + [Self.tracksList]).contains { list in
            geometry(list).divider(atX: point.x, y: point.y, columns(for: list), textSize: manager.textSize) != nil
        }
        guard onDivider || columnDrag != nil else { return nil }
        if #available(macOS 15, *) { return .columnResize }
        return .resizeLeftRight
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
        if let drag = columnDrag {
            let resized = geometry(drag.list).resizing(
                drag.columns, divider: drag.divider, by: point.x - drag.x, textSize: manager.textSize, minimum: manager.textSize.scaled(12))
            columnSizes[kind(of: drag.list)] = resized.map { $0.width ?? $0.weight }
            changed()
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
        if columnDrag != nil {
            columnDrag = nil
            manager.saveLayout()
        }
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

    /// On a row its menu; elsewhere the main menu.
    override func contextMenuRequested(at point: SkinPoint, event: NSEvent) {
        guard let list = list(at: point), let menu = contextMenu(list: list, row: row(at: point, in: list)) else {
            manager.showMainMenu(for: event, in: window.skinView)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: window.skinView)
    }

    /// On an album, playlist or track: play, enqueue, (Navidrome) keep
    /// offline, favourite; tracks go into playlists; playlists are made and
    /// deleted (also below the last one). On an artist favourite.
    private func contextMenu(list: Int, row: Int?) -> NSMenu? {
        let source = self.source, model = manager.model, viewIndex = self.viewIndex
        var play: [NSMenuItem] = [], toggles: [NSMenuItem] = [], playlistItems: [NSMenuItem] = []
        var favourites: [LibraryItem] = []
        let kind = kind(of: list)
        if kind == .playlists, source.editsPlaylists {
            playlistItems.append(NSMenuItem.newPlaylist(in: source, with: []) { [weak self] in self?.playlistsChanged($0, inView: viewIndex) })
        }
        switch (kind, row) {
        case (.albums, let row?), (.playlists, let row?):
            let item: LibraryItem = kind == .albums ? .album(albums[row]) : .playlist(playlists[row])
            play.append(NSMenuItem(title: "Play") { [weak self] in
                Task { if let tracks = try? await source.tracks(of: item) { self?.play(tracks, startingAt: 0) } }
            })
            play.append(NSMenuItem(title: "Enqueue") {
                Task {
                    if let tracks = try? await source.tracks(of: item) {
                        model.add(tracks: tracks.map(\.info), tagsKnown: source.tracksHaveTags)
                    }
                }
            })
            if let kept = source.isKeptOffline(item) {
                toggles.append(NSMenuItem(title: "Keep Offline", checked: kept) { source.setKeptOffline(item, !kept) })
            }
            favourites = [item]
            if kind == .playlists, source.editsPlaylists, playlists[row].editable {
                let playlist = playlists[row]
                playlistItems.append(NSMenuItem(title: "Delete Playlist…") { [weak self] in self?.deletePlaylist(playlist) })
            }
        case (.tracks, let row?), (.stations, let row?):
            if !(selection[list] ?? []).contains(row) {
                selection[list] = [row]
                changed()
            }
            play.append(NSMenuItem(title: "Play") { [weak self] in
                guard let self else { return }
                self.play(self.chosenTracks, startingAt: 0)
            })
            play.append(NSMenuItem(title: "Enqueue") { [weak self] in
                guard let self else { return }
                model.add(tracks: self.chosenTracks.map(\.info), tagsKnown: source.tracksHaveTags)
            })
            favourites = chosenTracks.map { .track($0.info) }
        case (.artists, let row?):
            favourites = [.artist(artists[row])]
        default:
            break
        }
        if let item = NSMenuItem.favourite(for: favourites, in: [source], then: { [weak self] added, error in
            self?.favouritesChanged(added, error: error, inView: viewIndex)
        }) {
            toggles.append(item)
        }
        if row != nil, kind == .tracks, let item = NSMenuItem.addToPlaylist(chosenTracks.map(\.info), in: [source], then: { [weak self] in
            self?.playlistsChanged($0, inView: viewIndex)
        }) {
            toggles.append(item)
        }
        let menu = NSMenu()
        for group in [play, toggles, playlistItems] where !group.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// Failures show in the status line; the favourites view lets go of what left it.
    private func favouritesChanged(_ added: Bool, error: Error?, inView index: Int) {
        if let error {
            status = "Favourites not changed: \(error.localizedDescription)"
            changed()
        } else if !added, index == viewIndex, view.listsFavourites {
            loadView()
        }
    }

    private func deletePlaylist(_ playlist: LibraryPlaylist) {
        let alert = NSAlert()
        alert.messageText = "Delete the playlist “\(playlist.name)”?"
        alert.informativeText = "Its songs stay in the library."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let source = self.source, viewIndex = self.viewIndex
        Task {
            do {
                try await source.deletePlaylist(playlist)
                playlistsChanged(.success(.deleted(playlist.name)), inView: viewIndex)
            } catch {
                playlistsChanged(.failure(error), inView: viewIndex)
            }
        }
    }

    /// A playlist made or deleted shows in the playlists view; the rest in the status line.
    private func playlistsChanged(_ result: Result<PlaylistChange, Error>, inView index: Int) {
        switch result {
        case .success(.added(let name)):
            status = PlaylistChange.added(to: name).message
        case .success(let change):
            if index == viewIndex, view.lists == .playlists { loadView() } else { status = change.message }
        case .failure(let error):
            status = "Playlist not changed: \(error.localizedDescription)"
        }
        changed()
    }

    /// The list under a point.
    private func list(at point: SkinPoint) -> Int? {
        ((0..<upperCount) + [Self.tracksList]).first { listRect($0).contains(x: point.x, y: point.y) }
    }

    /// The row of a list under a point; nil below the last one.
    private func row(at point: SkinPoint, in list: Int) -> Int? {
        guard let row = geometry(list).row(atY: point.y, firstVisible: scroll[list] ?? 0), row < rows(for: list).count else { return nil }
        return row
    }

    /// Self test: what a right click on a row offers.
    func contextMenuTitlesForTesting(list: Int, row: Int) -> [String] {
        contextMenu(list: list, row: row)?.titlesForTesting ?? []
    }

    /// Self test: a right click on a row, then a choice in its menu (and submenus).
    func chooseInContextMenuForTesting(_ titles: String..., list: Int, row: Int) {
        contextMenu(list: list, row: row)?.chooseForTesting(titles)
    }

    func setKeptOfflineForTesting(list: Int, row: Int, _ keep: Bool) {
        let item: LibraryItem = kind(of: list) == .albums ? .album(albums[row]) : .playlist(playlists[row])
        source.setKeptOffline(item, keep)
    }

    /// For the self test.
    var summary: String {
        "view=\(view.title) artists=\(artists.count) albums=\(albums.count) playlists=\(playlists.count) songs=\(tracks.count) status=\(statusText)"
    }

    /// Self test: the middle of a header cell, or the divider after it.
    func headerPointForTesting(list: Int, column: Int, divider: Bool = false) -> SkinPoint {
        let g = geometry(list), range = g.columnRanges(columns(for: list), textSize: manager.textSize)[column]
        return SkinPoint(x: divider ? range.upperBound : (range.lowerBound + range.upperBound) / 2, y: g.header!.y + g.header!.height / 2)
    }

    func rowsForTesting(list: Int) -> [[String]] { rows(for: list) }

    func columnWidthsForTesting(list: Int) -> [Int] {
        geometry(list).columnRanges(columns(for: list), textSize: manager.textSize).map(\.count)
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

extension NSMenuItem {
    /// "Favourite": checked when all of `items` are favourites in the libraries
    /// they are in; choosing it makes them all favourites, or none. nil when
    /// none of them can be one.
    @MainActor
    static func favourite(
        for items: [LibraryItem], in sources: [LibrarySource], then done: @escaping @MainActor (_ added: Bool, _ error: Error?) -> Void
    ) -> NSMenuItem? {
        let involved = sources.filter { source in items.contains { source.isFavourite($0) != nil } }
        guard !involved.isEmpty else { return nil }
        let add = involved.contains { source in items.contains { source.isFavourite($0) == false } }
        return NSMenuItem(title: "Favourite", checked: !add) {
            let changes = involved.map { $0.setFavourite(items, add) }
            Task {
                do {
                    for change in changes { try await change.value }
                    done(add, nil)
                } catch {
                    done(add, error)
                }
            }
        }
    }
}

/// What a playlist menu did, for the window to report.
enum PlaylistChange {
    case created(String), added(to: String), deleted(String)

    var message: String {
        switch self {
        case .created(let name): "Created playlist “\(name)”"
        case .added(let name): "Added to playlist “\(name)”"
        case .deleted(let name): "Deleted playlist “\(name)”"
        }
    }
}

extension NSMenuItem {
    /// "Add to Playlist": for each library some of `tracks` belong to, a new
    /// playlist and the ones it has. nil when no library can take them.
    @MainActor
    static func addToPlaylist(
        _ tracks: [TrackInfo], in sources: [LibrarySource], then done: @escaping @MainActor (Result<PlaylistChange, Error>) -> Void
    ) -> NSMenuItem? {
        let involved = sources.filter { $0.editsPlaylists && tracks.contains(where: $0.canAddToPlaylist) }
        guard !involved.isEmpty else { return nil }
        let menu = NSMenu()
        for source in involved {
            let own = tracks.filter(source.canAddToPlaylist)
            if involved.count > 1 {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                menu.addItem(.sectionHeader(title: source.windowTitle))
            }
            menu.addItem(newPlaylist(in: source, with: own, then: done))
            for playlist in source.editablePlaylists {
                menu.addItem(NSMenuItem(title: playlist.name) {
                    Task {
                        do {
                            try await source.add(own, to: playlist)
                            done(.success(.added(to: playlist.name)))
                        } catch {
                            done(.failure(error))
                        }
                    }
                })
            }
        }
        let item = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// "New Playlist…": asks for a name, then makes it with `tracks`.
    @MainActor
    static func newPlaylist(
        in source: LibrarySource, with tracks: [TrackInfo], then done: @escaping @MainActor (Result<PlaylistChange, Error>) -> Void
    ) -> NSMenuItem {
        NSMenuItem(title: "New Playlist…") {
            guard let name = WindowManager.askForText(title: "New Playlist", message: "A name for the playlist in \(source.windowTitle):", button: "Create")
            else { return }
            Task {
                do {
                    try await source.createPlaylist(named: name, with: tracks)
                    done(.success(.created(name)))
                } catch {
                    done(.failure(error))
                }
            }
        }
    }
}

extension NSMenu {
    /// Self test: the items, checked ones marked.
    var titlesForTesting: [String] {
        items.filter { !$0.isSeparatorItem }.map { $0.title + ($0.state == .on ? " ✓" : "") }
    }

    /// Self test: chooses an item as if clicked, following submenus by title.
    func chooseForTesting(_ titles: [String]) {
        guard let title = titles.first, let index = items.firstIndex(where: { $0.title == title }) else { return }
        if let submenu = items[index].submenu { submenu.chooseForTesting(Array(titles.dropFirst())) } else { performActionForItem(at: index) }
    }
}
