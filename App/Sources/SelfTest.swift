#if DEBUG
import AppKit
import ClassicUI
import SkinKit

/// Scripted walk through the UI for development, since window behaviour is
/// hard to unit test: `HAGTAMP_SELFTEST=<dir> Hagtamp.app/Contents/MacOS/Hagtamp`
/// drives the windows and writes a snapshot of the desktop layout after each
/// step, then quits. Optional `HAGTAMP_SELFTEST_SKIN=<skin>` for the shape test.
@MainActor
enum SelfTest {
    static func runIfRequested(_ manager: WindowManager) {
        guard let dir = ProcessInfo.processInfo.environment["HAGTAMP_SELFTEST"] else { return }
        let output = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var step = 0
        func snap(_ name: String) {
            step += 1
            let url = output.appendingPathComponent(String(format: "%02d-%@.png", step, name))
            try? snapshot(manager).pngData().write(to: url)
            print("selftest: \(url.lastPathComponent) \(layout(manager))")
        }

        let main = manager.main, eq = manager.equalizer, pl = manager.playlist
        snap("start")

        click(main, .play)
        snap("playing")
        press(main, .volume)
        snap("volume-pressed")
        release(main, .volume)

        click(main, .shade)
        snap("main-shaded")
        click(main, .shade)

        click(eq, .shade)
        snap("eq-shaded")
        click(eq, .shade)

        press(pl, .menu(.add))
        snap("add-menu")
        release(pl, .menu(.add))
        click(pl, .menu(.add))  // closes the sticky menu

        // Resize the playlist by two steps each way through the controller's drag path.
        manager.setPlaylistSizeForTesting(width: 2, height: 2)
        snap("playlist-resized")

        click(pl, .shade)
        snap("playlist-shaded")
        click(pl, .shade)

        manager.toggleDoubleSize()
        snap("double-size")
        manager.toggleDoubleSize()

        // Drag the equalizer away and back near its dock position: it must snap flush.
        manager.moveForTesting(.equalizer, dx: 300, dy: 40)
        snap("eq-detached")
        manager.moveForTesting(.equalizer, dx: -296, dy: -37)
        snap("eq-snapped-back")

        if let path = ProcessInfo.processInfo.environment["HAGTAMP_SELFTEST_SKIN"],
            let skin = try? Skin.load(contentsOf: URL(fileURLWithPath: path))
        {
            manager.setSkin(skin)
            snap("custom-skin")
            reportClickThrough(main, skin: skin)
        }
        NSApp.terminate(nil)
    }

    // MARK: - Pointer helpers

    private static func center(_ c: SkinWindowController, _ control: Control) -> SkinPoint {
        guard let rect = c.regions().region(for: control)?.rect else { fatalError("no \(control)") }
        return SkinPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
    }

    private static func event(_ type: NSEvent.EventType, _ c: SkinWindowController) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: c.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private static func press(_ c: SkinWindowController, _ control: Control) {
        c.mouseDown(at: center(c, control), event: event(.leftMouseDown, c))
    }

    private static func release(_ c: SkinWindowController, _ control: Control) {
        c.mouseUp(at: center(c, control), event: event(.leftMouseUp, c))
    }

    private static func click(_ c: SkinWindowController, _ control: Control) {
        press(c, control)
        release(c, control)
    }

    // MARK: - Output

    /// All visible windows drawn at their screen positions over a grey backdrop.
    private static func snapshot(_ manager: WindowManager) -> Bitmap {
        let windows = [manager.main, manager.equalizer, manager.playlist].filter { $0.window.isVisible }
        let union = windows.map(\.window.frame).reduce(NSRect.null) { $0.union($1) }.insetBy(dx: -8, dy: -8)
        var canvas = Bitmap(width: Int(union.width), height: Int(union.height), fill: PixelColor(rgb: 0x5A5A5A))
        for c in windows {
            let bitmap = c.renderMasked().scaled(by: manager.scale)
            let frame = c.window.frame
            canvas.draw(bitmap, from: bitmap.bounds, atX: Int(frame.minX - union.minX), y: Int(union.maxY - frame.maxY))
        }
        return canvas
    }

    private static func layout(_ manager: WindowManager) -> String {
        [("main", manager.main), ("eq", manager.equalizer), ("pl", manager.playlist)].map { name, c in
            let f = c.window.frame
            return c.window.isVisible ? "\(name)=\(Int(f.minX)),\(Int(f.maxY)) \(Int(f.width))x\(Int(f.height))" : "\(name)=hidden"
        }.joined(separator: " ")
    }

    /// Asks the window server which window is under a transparent pixel of the main window.
    private static func reportClickThrough(_ c: SkinWindowController, skin: Skin) {
        guard let polygons = skin.regions.main else {
            print("selftest: skin has no main window region")
            return
        }
        let mask = SkinRegions.mask(polygons, width: 275, height: 116)
        guard let hole = mask.indices.first(where: { !mask[$0] }) else { return }
        let (x, y) = (hole % 275, hole / 275)
        let frame = c.window.frame
        let scale = frame.width / 275
        let point = NSPoint(x: frame.minX + (CGFloat(x) + 0.5) * scale, y: frame.maxY - (CGFloat(y) + 0.5) * scale)
        let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        print("selftest: transparent pixel (\(x),\(y)) -> window \(hit), main is \(c.window.windowNumber): click-through \(hit != c.window.windowNumber ? "yes" : "no")")
    }
}

extension WindowManager {
    func setPlaylistSizeForTesting(width: Int, height: Int) {
        playlist.setSizeSteps(width: width, height: height)
        windowSizeChanged()
    }

    func moveForTesting(_ id: WindowID, dx: Int, dy: Int) {
        beginMove(id, from: .zero)
        continueMove(to: NSPoint(x: CGFloat(dx), y: CGFloat(-dy)))
        endMove()
    }
}
#endif
