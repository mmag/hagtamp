import AppKit
import ClassicUI
import SkinKit

@MainActor
final class PlaylistWindowController: SkinWindowController {
    private var widthSteps = 0
    private var heightSteps = 0
    private var firstVisibleRow = 0
    private var selectedRows: Set<Int> = []
    private var openMenu: PlaylistMenu?
    private var hoveredMenuItem: Int?
    /// The menu stays open after a plain click on its button.
    private var menuSticky = false
    private var menuPointerLeftButton = false
    private var resizeStart: (mouse: NSPoint, width: Int, height: Int)?

    init(manager: WindowManager) {
        super.init(id: .playlist, manager: manager)
    }

    private var width: Int { PlaylistWindowRenderer.baseWidth + widthSteps * 25 }
    private var height: Int { PlaylistWindowRenderer.baseHeight + heightSteps * 29 }

    override func regions() -> [ControlRegion] {
        PlaylistWindowLayout.regions(width: width, height: shade ? 14 : height, shade: shade)
    }
    override var bodyCursor: SkinCursorName {
        shade ? PlaylistWindowLayout.shadeBodyCursor : PlaylistWindowLayout.bodyCursor
    }
    override func pixelSize() -> (width: Int, height: Int) { (width, shade ? 14 : height) }
    override func renderBitmap() -> Bitmap { PlaylistWindowRenderer.render(manager.skin, state()) }

    private func state() -> PlaylistWindowState {
        let model = manager.model
        var s = PlaylistWindowState()
        s.focused = isFocused
        s.shade = shade
        s.pressed = pressed
        s.widthSteps = widthSteps
        s.heightSteps = heightSteps
        s.rows = model.tracks.enumerated().map { i, track in
            PlaylistRow(title: "\(i + 1). \(track.displayName)", duration: track.duration.map { Marquee.timeString(Int($0)) } ?? "")
        }
        s.firstVisibleRow = firstVisibleRow
        s.selectedRows = selectedRows
        s.currentRow = model.currentTrack == nil ? nil : model.currentIndex
        let seconds = { (i: Int) in model.tracks.indices.contains(i) ? Int(model.tracks[i].duration ?? 0) : 0 }
        let selected = selectedRows.map(seconds).reduce(0, +)
        let total = model.tracks.indices.map(seconds).reduce(0, +)
        s.runningTime = "\(Marquee.timeString(selected))/\(Marquee.timeString(total))"
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
        if let track = model.currentTrack {
            s.currentTitle = "\(model.currentIndex + 1). \(track.displayName)"
            s.currentDuration = model.duration.map { Marquee.timeString(Int($0)) } ?? ""
        }
        return s
    }

    private var maxFirstRow: Int {
        PlaylistWindowRenderer.maxFirstVisibleRow(rowCount: manager.model.tracks.count, height: height)
    }

    func setSizeSteps(width: Int, height: Int) {
        widthSteps = max(0, width)
        heightSteps = max(0, height)
        firstVisibleRow = min(firstVisibleRow, maxFirstRow)
    }

    private func scroll(to row: Int) {
        firstVisibleRow = min(maxFirstRow, max(0, row))
        manager.render()
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
        let model = manager.model
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

    override func contextMenuRequested(at point: SkinPoint, event: NSEvent) {
        manager.showMainMenu(for: event, in: window.skinView)
    }

    // MARK: - Presses

    override func interceptPress(at point: SkinPoint, event: NSEvent) -> Bool {
        guard let menu = openMenu, menuSticky else { return false }
        // A click while a menu is open picks an item or dismisses the menu.
        if let item = menuItem(at: point, in: menu) {
            perform(menu.items[item])
        }
        closeMenu()
        return true
    }

    override func pressBegan(_ control: Control, at point: SkinPoint, event: NSEvent) -> Bool {
        switch control {
        case .trackList:
            let row = firstVisibleRow + (point.y - 23) / PlaylistWindowRenderer.rowHeight
            guard point.y >= 23, manager.model.tracks.indices.contains(row) else {
                selectedRows = []
                manager.render()
                return false
            }
            selectedRows = [row]  // extended selection: stage 4
            if event.clickCount == 2 { manager.model.play(trackAt: row) }
            manager.render()
            return false
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

    override func pressDragged(_ control: Control, to point: SkinPoint, event: NSEvent) {
        switch control {
        case .resize:
            guard let start = resizeStart else { return }
            let now = NSEvent.mouseLocation
            let scale = CGFloat(manager.scale)
            let dx = (now.x - start.mouse.x) / scale, dy = (start.mouse.y - now.y) / scale
            let newWidth = max(0, start.width + Int((dx / 25).rounded()))
            let newHeight = shade ? heightSteps : max(0, start.height + Int((dy / 29).rounded()))
            guard newWidth != widthSteps || newHeight != heightSteps else { return }
            widthSteps = newWidth
            heightSteps = newHeight
            firstVisibleRow = min(firstVisibleRow, maxFirstRow)
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
        case .resize:
            resizeStart = nil
        case .menu(let menu):
            let item = menuItem(at: point, in: menu)
            if item == menu.items.count - 1 && !menuPointerLeftButton {
                // A plain click on the button: keep the menu open for a second click.
                menuSticky = true
                return
            }
            if let item { perform(menu.items[item]) }
            closeMenu()
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

    private func perform(_ item: PlaylistMenuItem) {
        let count = manager.model.tracks.count
        switch item {
        case .selectAll: selectedRows = Set(0..<count)
        case .selectNone: selectedRows = []
        case .invertSelection: selectedRows = Set(0..<count).subtracting(selectedRows)
        default: break  // playlist editing: stage 4
        }
    }
}
