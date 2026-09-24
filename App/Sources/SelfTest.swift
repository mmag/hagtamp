#if DEBUG
import AVFAudio
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
        setvbuf(stdout, nil, _IOLBF, 0)  // progress stays visible if a step hangs
        let output = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var step = 0
        let snap: (String) -> Void = { name in
            step += 1
            let url = output.appendingPathComponent(String(format: "%02d-%@.png", step, name))
            try? snapshot(manager).pngData().write(to: url)
            print("selftest: \(url.lastPathComponent) \(layout(manager))")
        }

        snap("start")

        Task { @MainActor in
            checkPresetMenu(manager)
            checkRaising(manager)
            await audioSteps(manager, snap: snap)
            await playlistSteps(manager, snap: snap)
            uiSteps(manager, snap: snap)
            NSApp.terminate(nil)
        }
    }

    /// A foreign window covering the equalizer must go below it once the main window is clicked.
    private static func checkRaising(_ manager: WindowManager) {
        let foreign = NSWindow(contentRect: manager.equalizer.window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        foreign.isReleasedWhenClosed = false
        foreign.orderFront(nil)
        func rank(_ w: NSWindow) -> Int { NSApp.orderedWindows.firstIndex { $0 === w } ?? -1 }
        let before = rank(manager.equalizer.window) < rank(foreign)
        manager.main.mouseDown(at: SkinPoint(x: 100, y: 5), event: event(.leftMouseDown, manager.main))
        manager.main.mouseUp(at: SkinPoint(x: 100, y: 5), event: event(.leftMouseUp, manager.main))
        let after = rank(manager.equalizer.window) < rank(foreign)
        let mainOnTop = rank(manager.main.window) == 0
        print("selftest: raise: eq above foreign before=\(before) after=\(after), main on top=\(mainOnTop)")
        foreign.close()
    }

    /// Picks "Rock" from the PRESETS menu the way AppKit would.
    private static func checkPresetMenu(_ manager: WindowManager) {
        let menu = manager.equalizer.presetsMenu()
        guard let load = menu.item(withTitle: "Load")?.submenu, let rock = load.item(withTitle: "Rock") else {
            print("selftest: preset menu: no Load > Rock")
            return
        }
        let before = manager.model.bands[0]
        print("selftest: preset item enabled=\(rock.isEnabled) target=\(String(describing: rock.target)) action=\(String(describing: rock.action))")
        let sent = NSApp.sendAction(rock.action!, to: rock.target, from: rock)
        print("selftest: preset sent=\(sent) band0 \(before) -> \(manager.model.bands[0])")
        load.performActionForItem(at: load.index(of: rock))
        print("selftest: preset performAction band0 -> \(manager.model.bands[0])")
    }

    /// Plays two generated tones silently: time, visualizer, gapless handover.
    private static func audioSteps(_ manager: WindowManager, snap: (String) -> Void) async {
        let model = manager.model
        let tones = [(1000.0, "tone-1k"), (220.0, "tone-220")].compactMap { makeTone(frequency: $0.0, name: $0.1) }
        model.load(tones, play: true)
        model.volume = 0  // silent (the self test has its own settings)
        try? await Task.sleep(for: .milliseconds(1500))
        print("selftest: status=\(model.status) index=\(model.currentIndex ?? -1) elapsed=\(String(format: "%.2f", model.elapsed)) duration=\(model.duration ?? -1) title=\(model.currentTrack?.displayName ?? "-") kbps=\(model.currentTrack?.bitrate ?? -1)")
        snap("playing-analyzer")

        manager.visualizerSettings.mode = .oscilloscope
        try? await Task.sleep(for: .milliseconds(300))
        snap("playing-oscilloscope")
        manager.visualizerSettings.mode = .analyzer

        model.seek(to: 0.97)
        try? await Task.sleep(for: .milliseconds(800))
        print("selftest: after end of first track index=\(model.currentIndex ?? -1) status=\(model.status) elapsed=\(String(format: "%.2f", model.elapsed))")
        snap("gapless-second-track")

        model.pause()
        try? await Task.sleep(for: .milliseconds(300))
        snap("paused")
        model.stop()
        try? await Task.sleep(for: .milliseconds(200))
        print("selftest: stopped status=\(model.status)")
    }

    /// Selection, dragging, sorting and keyboard editing on nine generated files.
    private static func playlistSteps(_ manager: WindowManager, snap: (String) -> Void) async {
        let model = manager.model, pl = manager.playlist
        let names = ["delta", "alpha", "echo", "charlie", "bravo", "foxtrot", "golf", "hotel", "india"]
        let files = names.enumerated().compactMap { i, name in
            makeTone(frequency: 200 + Double(i) * 100, name: name, seconds: Double(i + 1))
        }
        model.load(files, play: false)
        manager.setPlaylistSizeForTesting(width: 1, height: 2)
        try? await Task.sleep(for: .milliseconds(500))  // tags are read in the background
        func order() -> String {
            model.playlist.entries.map { $0.url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "hagtamp-", with: "") }
                .joined(separator: " ")
        }
        func rowPoint(_ row: Int) -> SkinPoint { SkinPoint(x: 60, y: 23 + row * 13 + 6) }

        pl.mouseDown(at: rowPoint(1), event: event(.leftMouseDown, pl))
        pl.mouseUp(at: rowPoint(1), event: event(.leftMouseUp, pl))
        pl.mouseDown(at: rowPoint(3), event: event(.leftMouseDown, pl, modifiers: .shift))
        pl.mouseUp(at: rowPoint(3), event: event(.leftMouseUp, pl, modifiers: .shift))
        print("selftest: selected=\(model.playlist.selectedIndices) order=\(order())")
        snap("pl-selection")

        // Drag the selection two rows down.
        pl.mouseDown(at: rowPoint(2), event: event(.leftMouseDown, pl))
        pl.mouseDragged(to: rowPoint(4), event: event(.leftMouseDragged, pl))
        pl.mouseUp(at: rowPoint(4), event: event(.leftMouseUp, pl))
        print("selftest: dragged selected=\(model.playlist.selectedIndices) order=\(order())")
        snap("pl-dragged")

        model.editPlaylist { $0.sort(by: .fileName) }
        print("selftest: sorted order=\(order())")

        // Home, Shift+Down twice, Delete.
        _ = pl.keyDown(key(115, pl))
        _ = pl.keyDown(key(125, pl, modifiers: .shift))
        _ = pl.keyDown(key(125, pl, modifiers: .shift))
        print("selftest: keyboard selected=\(model.playlist.selectedIndices)")
        _ = pl.keyDown(key(51, pl))
        print("selftest: after delete count=\(model.playlist.count) order=\(order())")
        snap("pl-after-delete")

        pl.mouseDown(at: rowPoint(2), event: event(.leftMouseDown, pl, clickCount: 2))
        pl.mouseUp(at: rowPoint(2), event: event(.leftMouseUp, pl, clickCount: 2))
        try? await Task.sleep(for: .milliseconds(300))
        print("selftest: double-click plays index=\(model.currentIndex ?? -1) status=\(model.status) marquee=\(manager.marqueeText)")
        snap("pl-playing")
        model.stop()

        // Album art from a cover image next to the files.
        writeCover(next: files[0])
        manager.toggleAlbumArt()
        try? await Task.sleep(for: .milliseconds(600))
        print("selftest: album art visible=\(manager.isVisible(.albumArt)) cover=\(manager.albumArt.hasCover) frame=\(manager.albumArt.window.frame)")
        snap("album-art")
        manager.toggleAlbumArt()

        let saved = Storage.supportDirectory.appendingPathComponent("playlist.m3u8")
        let lines = ((try? String(contentsOf: saved, encoding: .utf8)) ?? "").split(separator: "\n").count
        print("selftest: saved playlist lines=\(lines)")
        manager.setPlaylistSizeForTesting(width: 0, height: 0)
    }

    /// A striped test cover (cover.png) in the folder of `track`.
    private static func writeCover(next track: URL) {
        var cover = Bitmap(width: 64, height: 64, fill: PixelColor(rgb: 0x2060C0))
        for y in stride(from: 0, to: 64, by: 8) { cover.fill(PixelRect(x: 0, y: y, width: 64, height: 4), with: PixelColor(rgb: 0xF0C040)) }
        try? cover.pngData().write(to: track.deletingLastPathComponent().appendingPathComponent("cover.png"))
    }

    private static func key(_ code: UInt16, _ c: SkinWindowController, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: c.window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    private static func makeTone(frequency: Double, name: String, seconds: Double = 3) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-\(name).wav")
        let rate = 44100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(seconds * rate))
        else { return nil }
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(file.processingFormat.channelCount) {
            for i in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][i] = 0.6 * Float(sin(2 * .pi * frequency * Double(i) / rate))
            }
        }
        try? file.write(from: buffer)
        return url
    }

    private static func uiSteps(_ manager: WindowManager, snap: (String) -> Void) {
        let main = manager.main, eq = manager.equalizer, pl = manager.playlist
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
        click(pl, .trackList)  // a click outside the sticky menu closes it

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
    }

    // MARK: - Pointer helpers

    private static func center(_ c: SkinWindowController, _ control: Control) -> SkinPoint {
        guard let rect = c.regions().region(for: control)?.rect else { fatalError("no \(control)") }
        return SkinPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
    }

    private static func event(
        _ type: NSEvent.EventType, _ c: SkinWindowController, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: c.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
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
        let windows = [manager.main, manager.equalizer, manager.playlist, manager.albumArt].filter { $0.window.isVisible }
        let union = windows.map(\.window.frame).reduce(NSRect.null) { $0.union($1) }.insetBy(dx: -8, dy: -8)
        var canvas = Bitmap(width: Int(union.width), height: Int(union.height), fill: PixelColor(rgb: 0x5A5A5A))
        for c in windows {
            let bitmap = c.renderMasked().scaled(by: manager.scale)
            let frame = c.window.frame
            let x = Int(frame.minX - union.minX), y = Int(union.maxY - frame.maxY)
            canvas.draw(bitmap, from: bitmap.bounds, atX: x, y: y)
            // Subviews (the album art image) are drawn by AppKit, not in the bitmap.
            for view in c.window.skinView.subviews {
                guard let imageView = view as? NSImageView, let image = imageView.image,
                    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { continue }
                let r = view.frame
                let height = canvas.height
                canvas.withCGContext { ctx in
                    ctx.draw(cg, in: CGRect(x: CGFloat(x) + r.minX, y: CGFloat(height - y) - r.maxY, width: r.width, height: r.height))
                }
            }
        }
        return canvas
    }

    private static func layout(_ manager: WindowManager) -> String {
        [("main", manager.main), ("eq", manager.equalizer), ("pl", manager.playlist), ("art", manager.albumArt)].map { name, c in
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
