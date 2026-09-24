import AppKit
import AudioCore
import ClassicUI
import PlayerCore
import SkinKit
import UniformTypeIdentifiers

@MainActor
final class PlaylistWindowController: SkinWindowController {
    private var widthSteps = 0
    private var heightSteps = 0
    private var firstVisibleRow = 0
    private var openMenu: PlaylistMenu?
    private var hoveredMenuItem: Int?
    /// The menu stays open after a plain click on its button.
    private var menuSticky = false
    private var menuPointerLeftButton = false
    private var resizeStart: (mouse: NSPoint, width: Int, height: Int)?
    /// Dragging the selection: pointer row at the start and rows moved so far.
    private var dragStart: (y: Int, moved: Int)?
    private var lastCurrentID: UUID?

    init(manager: WindowManager) {
        super.init(id: .playlist, manager: manager)
    }

    private var model: PlayerModel { manager.model }
    private var playlist: Playlist { model.playlist }
    private var width: Int { PlaylistWindowRenderer.baseWidth + widthSteps * 25 }
    private var height: Int { PlaylistWindowRenderer.baseHeight + heightSteps * 29 }
    private var visibleRows: Int { PlaylistWindowRenderer.visibleRowCount(height: height) }

    override func regions() -> [ControlRegion] {
        PlaylistWindowLayout.regions(width: width, height: shade ? 14 : height, shade: shade)
    }
    override var bodyCursor: SkinCursorName {
        shade ? PlaylistWindowLayout.shadeBodyCursor : PlaylistWindowLayout.bodyCursor
    }
    override func pixelSize() -> (width: Int, height: Int) { (width, shade ? 14 : height) }

    override func renderBitmap() -> Bitmap {
        followCurrentTrack()
        return PlaylistWindowRenderer.render(manager.skin, state())
    }

    private func state() -> PlaylistWindowState {
        var s = PlaylistWindowState()
        s.focused = isFocused
        s.shade = shade
        s.pressed = pressed
        s.widthSteps = widthSteps
        s.heightSteps = heightSteps
        s.rows = playlist.entries.enumerated().map { i, entry in
            PlaylistRow(
                title: "\(i + 1). \(entry.info.displayName)",
                duration: entry.info.duration.map { Marquee.timeString(Int($0)) } ?? "")
        }
        s.firstVisibleRow = firstVisibleRow
        s.selectedRows = Set(playlist.selectedIndices)
        s.currentRow = playlist.currentIndex
        let time = playlist.runningTime
        s.runningTime = "\(Marquee.timeString(time.selected))/\(Marquee.timeString(time.total))\(time.incomplete ? "+" : "")"
        if model.status != .stopped, manager.timeVisible {
            let elapsed = Int(model.elapsed)
            if manager.timeMode == .remaining, let duration = model.duration {
                s.miniTime = TimeDisplay(seconds: max(0, Int(duration) - elapsed), mode: .remaining)
            } else {
                s.miniTime = TimeDisplay(seconds: elapsed)
            }
        }
        s.openMenu = openMenu
        s.hoveredMenuItem = hoveredMenuItem
        if let track = model.displayedTrack {
            s.currentTitle = (model.currentIndex.map { "\($0 + 1). " } ?? "") + track.displayName
            s.currentDuration = model.duration.map { Marquee.timeString(Int($0)) } ?? ""
        }
        return s
    }

    // MARK: - Scrolling

    private var maxFirstRow: Int {
        PlaylistWindowRenderer.maxFirstVisibleRow(rowCount: playlist.count, height: height)
    }

    private func scroll(to row: Int) {
        firstVisibleRow = min(maxFirstRow, max(0, row))
        manager.render()
    }

    /// Scrolls just enough to show `row`.
    private func reveal(_ row: Int) {
        if row < firstVisibleRow {
            firstVisibleRow = row
        } else if row >= firstVisibleRow + visibleRows {
            firstVisibleRow = row - visibleRows + 1
        }
        firstVisibleRow = min(maxFirstRow, max(0, firstVisibleRow))
    }

    /// When a new track starts, bring it into view (Winamp's default).
    private func followCurrentTrack() {
        let current = playlist.currentID
        guard current != lastCurrentID else { return }
        lastCurrentID = current
        if let index = playlist.currentIndex { reveal(index) }
    }

    private func row(at point: SkinPoint) -> Int? {
        guard point.y >= 23 else { return nil }
        let row = firstVisibleRow + (point.y - 23) / PlaylistWindowRenderer.rowHeight
        return playlist.entries.indices.contains(row) ? row : nil
    }

    func setSizeSteps(width: Int, height: Int) {
        widthSteps = max(0, width)
        heightSteps = max(0, height)
        firstVisibleRow = min(firstVisibleRow, maxFirstRow)
    }

    // MARK: - Sliders and buttons

    override func sliderValue(_ control: Control) -> Double {
        guard control == .scrollBar, maxFirstRow > 0 else { return 0 }
        return Double(firstVisibleRow) / Double(maxFirstRow)
    }

    override func sliderChanged(_ control: Control, value: Double) {
        if control == .scrollBar { scroll(to: Int((value * Double(maxFirstRow)).rounded())) }
    }

    override func buttonClicked(_ control: Control) {
        switch control {
        case .shade: manager.toggleShade(.playlist)
        case .close: manager.setVisible(.playlist, false)
        case .scrollUp: scroll(to: firstVisibleRow - 1)
        case .scrollDown: scroll(to: firstVisibleRow + 1)
        case .previous: model.previous()
        case .play: model.play()
        case .pause: model.pause()
        case .stop: model.stop()
        case .next: model.next()
        case .eject: manager.openFiles()
        default: break
        }
    }

    override func scrolled(by delta: CGFloat) {
        scroll(to: firstVisibleRow - Int(delta.rounded()))
    }

    // MARK: - Presses

    override func interceptPress(at point: SkinPoint, event: NSEvent) -> Bool {
        guard let menu = openMenu, menuSticky else { return false }
        // A click while a menu is open picks an item or dismisses the menu.
        let item = menuItem(at: point, in: menu)
        closeMenu()
        if let item { perform(menu.items[item], event: event) }
        return true
    }

    override func pressBegan(_ control: Control, at point: SkinPoint, event: NSEvent) -> Bool {
        switch control {
        case .trackList:
            return trackListPressed(at: point, event: event)
        case .resize:
            resizeStart = (NSEvent.mouseLocation, widthSteps, heightSteps)
            return true
        case .menu(let menu):
            openMenu = menu
            hoveredMenuItem = menu.items.count - 1
            menuSticky = false
            menuPointerLeftButton = false
            manager.render()
            return true
        case .miniTime:
            manager.timeMode = manager.timeMode == .elapsed ? .remaining : .elapsed
            manager.render()
            return false
        default:
            return false
        }
    }

    /// Winamp 2 selection: click selects, Shift extends from the anchor,
    /// Ctrl (⌘ here) toggles; dragging a selected entry moves the selection.
    private func trackListPressed(at point: SkinPoint, event: NSEvent) -> Bool {
        guard let row = row(at: point) else {
            model.changeSelection { $0.selectNone() }
            return false
        }
        let flags = event.modifierFlags
        if flags.contains(.shift) {
            model.changeSelection { $0.extendSelection(to: row) }
            return false
        }
        if flags.contains(.command) {
            model.changeSelection { $0.toggleSelection(row) }
            return false
        }
        if !playlist.isSelected(row) { model.changeSelection { $0.select(row) } }
        if event.clickCount == 2 {
            model.play(trackAt: row)
            return false
        }
        dragStart = (point.y, 0)
        return true
    }

    override func pressDragged(_ control: Control, to point: SkinPoint, event: NSEvent) {
        switch control {
        case .trackList:
            guard let start = dragStart else { return }
            let rows = Int((Double(point.y - start.y) / Double(PlaylistWindowRenderer.rowHeight)).rounded(.down))
            guard rows != start.moved else { return }
            var applied = 0
            model.editPlaylist { applied = $0.moveSelection(by: rows - start.moved) }
            dragStart = (start.y, start.moved + applied)
        case .resize:
            guard let start = resizeStart else { return }
            let now = NSEvent.mouseLocation
            let scale = CGFloat(manager.scale)
            let dx = (now.x - start.mouse.x) / scale, dy = (start.mouse.y - now.y) / scale
            let newWidth = max(0, start.width + Int((dx / 25).rounded()))
            let newHeight = shade ? heightSteps : max(0, start.height + Int((dy / 29).rounded()))
            guard newWidth != widthSteps || newHeight != heightSteps else { return }
            setSizeSteps(width: newWidth, height: newHeight)
            manager.windowSizeChanged()
        case .menu(let menu):
            let item = menuItem(at: point, in: menu)
            if item != menu.items.count - 1 { menuPointerLeftButton = true }
            if item != hoveredMenuItem {
                hoveredMenuItem = item
                manager.render()
            }
        default:
            break
        }
    }

    override func pressEnded(_ control: Control, at point: SkinPoint, event: NSEvent) {
        switch control {
        case .trackList:
            dragStart = nil
        case .resize:
            resizeStart = nil
        case .menu(let menu):
            let item = menuItem(at: point, in: menu)
            if item == menu.items.count - 1 && !menuPointerLeftButton {
                // A plain click on the button: keep the menu open for a second click.
                menuSticky = true
                return
            }
            closeMenu()
            if let item { perform(menu.items[item], event: event) }
        default:
            break
        }
    }

    private func menuItem(at point: SkinPoint, in menu: PlaylistMenu) -> Int? {
        menu.items.indices.first { index in
            PlaylistWindowLayout.menuItemRect(menu, item: index, width: width, height: height).contains(x: point.x, y: point.y)
        }
    }

    private func closeMenu() {
        openMenu = nil
        hoveredMenuItem = nil
        menuSticky = false
        manager.render()
    }

    // MARK: - Keyboard

    override func keyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let anchor = playlist.anchor ?? playlist.selectedIndices.first ?? -1
        func moveFocus(to row: Int) {
            guard !playlist.isEmpty else { return }
            let target = min(max(0, row), playlist.count - 1)
            if flags.contains(.shift) {
                // Extend from the fixed anchor; the focus moves with the keys.
                model.changeSelection { $0.extendSelection(to: target) }
            } else {
                model.changeSelection { $0.select(target) }
            }
            reveal(target)
            manager.render()
        }
        switch event.keyCode {
        case 126 where flags.contains(.option), 125 where flags.contains(.option):  // ⌥↑ ⌥↓ move the selection
            model.editPlaylist { $0.moveSelection(by: event.keyCode == 126 ? -1 : 1) }
            if let first = playlist.selectedIndices.first { reveal(first) }
        case 126: moveFocus(to: (flags.contains(.shift) ? focusRow : anchor) - 1)
        case 125: moveFocus(to: (flags.contains(.shift) ? focusRow : anchor) + 1)
        case 116: moveFocus(to: anchor - visibleRows)  // page up
        case 121: moveFocus(to: anchor + visibleRows)  // page down
        case 115: moveFocus(to: 0)  // home
        case 119: moveFocus(to: playlist.count - 1)  // end
        case 36, 76:  // return, enter
            if anchor >= 0 { model.play(trackAt: anchor) }
        case 51, 117:  // delete, forward delete
            model.editPlaylist { $0.removeSelected() }
        default:
            if flags == .command, event.charactersIgnoringModifiers == "a" {
                model.changeSelection { $0.selectAll() }
                return true
            }
            return super.keyDown(event)
        }
        return true
    }

    /// The moving end of a Shift+arrow selection (the anchor stays fixed).
    private var focusRow: Int {
        let selected = playlist.selectedIndices
        guard let anchor = playlist.anchor, let first = selected.first, let last = selected.last else {
            return playlist.anchor ?? -1
        }
        return first < anchor ? first : last
    }

    // MARK: - Menus

    private func perform(_ item: PlaylistMenuItem, event: NSEvent) {
        switch item {
        case .addURL: addURL()
        case .addDirectory: addFiles(directories: true)
        case .addFile: addFiles(directories: false)
        case .removeMisc: popUp(removeMiscMenu(), event)
        case .removeAll: model.editPlaylist { $0.removeAll() }
        case .crop: model.editPlaylist { $0.crop() }
        case .removeSelected: model.editPlaylist { $0.removeSelected() }
        case .invertSelection: model.changeSelection { $0.invertSelection() }
        case .selectNone: model.changeSelection { $0.selectNone() }
        case .selectAll: model.changeSelection { $0.selectAll() }
        case .sortList: popUp(sortMenu(), event)
        case .fileInfo: showInfoForSelection()
        case .miscOptions: popUp(miscOptionsMenu(), event)
        case .newList: model.editPlaylist { $0.removeAll() }
        case .saveList: saveList()
        case .loadList: loadList()
        }
    }

    private func popUp(_ menu: NSMenu, _ event: NSEvent) {
        NSMenu.popUpContextMenu(menu, with: event, for: window.skinView)
    }

    private func removeMiscMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Remove duplicate entries") { [weak self] in self?.model.editPlaylist { $0.removeDuplicates() } })
        menu.addItem(NSMenuItem(title: "Remove all dead files") { [weak self] in self?.model.editPlaylist { $0.removeDeadFiles() } })
        return menu
    }

    private func sortMenu() -> NSMenu {
        let menu = NSMenu()
        let sorts: [(String, Playlist.SortKey)] = [
            ("Sort list by title", .title), ("Sort list by filename", .fileName), ("Sort list by path and filename", .path),
        ]
        for (title, key) in sorts {
            menu.addItem(NSMenuItem(title: title) { [weak self] in self?.model.editPlaylist { $0.sort(by: key) } })
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Reverse list") { [weak self] in self?.model.editPlaylist { $0.reverse() } })
        menu.addItem(NSMenuItem(title: "Randomize list") { [weak self] in self?.model.editPlaylist { $0.randomize() } })
        return menu
    }

    private func miscOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Jump to file…") { [weak self] in self?.manager.showJumpToFile() })
        return menu
    }

    override func contextMenuRequested(at point: SkinPoint, event: NSEvent) {
        guard regions().hit(x: point.x, y: point.y)?.control == .trackList, let row = row(at: point) else {
            manager.showMainMenu(for: event, in: window.skinView)
            return
        }
        if !playlist.isSelected(row) { model.changeSelection { $0.select(row) } }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Play item") { [weak self] in self?.model.play(trackAt: row) })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Remove item(s)") { [weak self] in self?.model.editPlaylist { $0.removeSelected() } })
        menu.addItem(NSMenuItem(title: "Crop item(s)") { [weak self] in self?.model.editPlaylist { $0.crop() } })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "File info…") { [weak self] in self?.showInfoForSelection() })
        popUp(menu, event)
    }

    // MARK: - Adding, loading, saving

    private func addFiles(directories: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        if !directories {
            panel.allowedContentTypes = (TrackInfo.supportedExtensions.union(PlaylistFile.extensions))
                .compactMap { UTType(filenameExtension: $0) }
        }
        guard panel.runModal() == .OK else { return }
        model.add(panel.urls)
    }

    private func addURL() {
        let alert = NSAlert()
        alert.messageText = "Add URL"
        alert.informativeText = "Enter a stream or file URL. (Streams play from stage 5.)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "http://"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
            let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)), url.scheme != nil
        else { return }
        model.editPlaylist { $0.insert([TrackInfo(url: url)]) }
    }

    private static var playlistTypes: [UTType] {
        PlaylistFile.extensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    private func loadList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.playlistTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.load([url], play: false)
    }

    private func saveList() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.playlistTypes
        panel.nameFieldStringValue = "Playlist.m3u8"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format: PlaylistFile.Format = url.pathExtension.lowercased() == "pls" ? .pls : .m3u8
        let data = PlaylistFile.data(for: playlist.entries.map(\.info), format: format, base: url.deletingLastPathComponent())
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func showInfoForSelection() {
        guard let index = playlist.selectedIndices.first ?? playlist.currentIndex else { return }
        FileInfoPanel.show(playlist[index].info)
    }

    /// Files dropped on the list go where they were dropped.
    func insertionRow(at point: SkinPoint) -> Int {
        guard point.y >= 23 else { return firstVisibleRow }
        return min(playlist.count, firstVisibleRow + (point.y - 23 + PlaylistWindowRenderer.rowHeight / 2) / PlaylistWindowRenderer.rowHeight)
    }
}
