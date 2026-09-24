#if DEBUG
import AVFAudio
import AppKit
import ClassicUI
import NavidromeKit
import SFBAudioEngine
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

        manager.textSize = .normal  // steps click rows by pixel, at Winamp's size
        snap("start")
        if let icon = NSApp.applicationIconImage, let tiff = icon.tiffRepresentation {
            print("selftest: app icon size=\(icon.size) reps=\(icon.representations.map { Int($0.pixelsWide) })")
            try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("app-icon.png"))
        } else {
            print("selftest: app icon: none")
        }

        Task { @MainActor in
            checkPresetMenu(manager)
            await snapPreferences(to: output, tabs: PreferencesWindowController.Tab.allCases)
            checkRaising(manager)
            await audioSteps(manager, snap: snap)
            await resumeSteps(manager)
            await playlistSteps(manager, snap: snap)
            await localLibrarySteps(manager, snap: snap)
            await lyricsSteps(manager, snap: snap)
            await snapPreferences(to: output, tabs: [.library], suffix: "-scanned")
            await navidromeSteps(manager, snap: snap)
            uiSteps(manager, snap: snap)
            await textSizeSteps(manager, snap: snap)
            await visualizationSteps(manager, output: output)
            await controlSteps(manager, output: output)
            layoutSteps(manager)
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

        // Next while playing must keep playing.
        model.onEngineEvent = { event in print("selftest: engine event \(event) status=\(model.status)") }
        model.next()
        try? await Task.sleep(for: .milliseconds(1200))
        print("selftest: after next index=\(model.currentIndex ?? -1) status=\(model.status) engine=\(model.engine.state) elapsed=\(String(format: "%.2f", model.elapsed))")
        model.previous()
        try? await Task.sleep(for: .milliseconds(800))
        print("selftest: after previous index=\(model.currentIndex ?? -1) status=\(model.status) engine=\(model.engine.state) elapsed=\(String(format: "%.2f", model.elapsed))")
        model.onEngineEvent = nil

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

    /// Library browsing and playback against scripts/navidrome_dev.sh, when it runs.
    /// HAGTAMP_SELFTEST_NAVIDROME points elsewhere (e.g. a throttling proxy, to stream for real).
    /// A local track with an .lrc next to it (made-up words): the current line
    /// follows the song, a click on a line jumps there.
    private static func lyricsSteps(_ manager: WindowManager, snap: (String) -> Void) async {
        let model = manager.model
        guard let tone = makeTone(frequency: 520, name: "lyrics", seconds: 6) else { return }
        try? """
            [00:00.30]Test words for the first line
            [00:01.50]A second made-up line that is long enough to need wrapping in the window
            [00:03.00]Third line
            [00:04.50]Last line of the test
            """.write(to: tone.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
        model.load([tone], play: true)
        manager.toggleLyrics()
        await wait("lyrics loaded") { manager.lyrics.summary.hasPrefix("lines=4 synced=true") }
        await wait("lyrics follow the song", seconds: 4) { manager.lyrics.summary.contains("current=1 ") }
        print("selftest: lyrics \(manager.lyrics.summary)")
        snap("lyrics")
        manager.lyrics.clickLineForTesting(3)
        await wait("lyrics click jumps") { model.elapsed >= 4.4 && manager.lyrics.summary.contains("current=3 ") }
        model.stop()
        manager.toggleLyrics()
    }

    /// With the option on, a relaunch continues the track where it was; Stop forgets the spot.
    private static func resumeSteps(_ manager: WindowManager) async {
        let model = manager.model
        model.resumesPosition = true
        model.play(trackAt: 0)
        await wait("resume: playing") { model.status == .playing && model.elapsed > 0.2 }
        model.seek(to: 0.6)
        try? await Task.sleep(for: .milliseconds(300))
        model.pause()
        try? await Task.sleep(for: .milliseconds(100))
        let saved = model.elapsed
        model.savePosition(force: true)
        model.relaunchForTesting()
        model.play()
        await wait("resume: continues where it was") { model.status == .playing && model.elapsed >= saved - 0.1 && model.elapsed < saved + 1 }
        print("selftest: resume saved=\(String(format: "%.2f", saved)) now=\(String(format: "%.2f", model.elapsed))")
        model.stop()
        model.relaunchForTesting()
        model.play()
        await wait("resume: stop forgets the spot") { model.status == .playing && model.elapsed > 0.05 && model.elapsed < saved - 0.5 }
        model.stop()
        model.resumesPosition = false
    }

    /// The visualization window draws presets with Metal and switches on Space;
    /// every bundled preset is also drawn offscreen into one sheet.
    private static func visualizationSteps(_ manager: WindowManager, output: URL) async {
        let model = manager.model, vis = manager.visualization
        if let tone = makeTone(frequency: 330, name: "visualization", seconds: 8) { model.load([tone], play: true) }
        manager.toggleVisualization()
        await wait("visualization draws", seconds: 6) { vis.framesDrawn > 30 && vis.currentPresetName != nil }
        print("selftest: visualization preset=\(vis.currentPresetName ?? "-") frames=\(vis.framesDrawn) presets=\(vis.library.presets.count)")
        await wait("visualization reaches the window", seconds: 5) { (vis.onScreenBrightnessForTesting() ?? 0) > 1 }
        print("selftest: visualization on screen brightness=\(vis.onScreenBrightnessForTesting().map { String(format: "%.1f", $0) } ?? "-")")
        let counted = vis.framesDrawn
        try? await Task.sleep(for: .seconds(2))
        let fps = Double(vis.framesDrawn - counted) / 2
        print("selftest: visualization at 60 fps: \(fps >= 55 ? "ok" : "SLOW") (\(String(format: "%.1f", fps)))")
        vis.toggleFullScreen()
        try? await Task.sleep(for: .milliseconds(300))
        let screen = vis.window.screen?.frame.size ?? .zero
        print("selftest: visualization fills the screen: \(vis.drawingSizeForTesting == screen ? "ok" : "WRONG SIZE \(vis.drawingSizeForTesting) on \(screen)")")
        vis.toggleFullScreen()
        try? await Task.sleep(for: .milliseconds(100))
        print("selftest: visualization back in its window: \(vis.drawingSizeForTesting == vis.contentSizeForTesting ? "ok" : "WRONG SIZE \(vis.drawingSizeForTesting)")")
        let first = vis.currentPresetName
        _ = vis.handleVisualizationKey(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: vis.window.windowNumber,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!)
        await wait("next preset on Space") { vis.currentPresetName != first }
        if let sheet = vis.presetSheetForTesting() {
            try? sheet.write(to: output.appendingPathComponent("visualization-presets.png"))
        }
        model.stop()
        manager.toggleVisualization()
    }

    /// Larger text: rows grow with it, fewer fit, clicks still find their row.
    private static func textSizeSteps(_ manager: WindowManager, snap: (String) -> Void) async {
        let library = manager.localLibrary
        manager.toggleLocalLibrary()
        library.chooseViewForTesting(0)
        await wait("library for text size") { library.summary.contains("artists=3") }
        library.selectForTesting(row: 0, in: 0)
        await wait("library tracks for text size") { !library.summary.contains("songs=0 ") }
        manager.textSize = TextSize(scale: 1.5)
        snap("text-150")
        print("selftest: text size 150%: row height \(manager.textSize.rowHeight) px, font \(manager.textSize.fontSize) pt")
        manager.toggleLocalLibrary()
        manager.textSize = .normal
    }

    /// Winamp's menu and keys, media controls, the stop variants and skins.
    private static func controlSteps(_ manager: WindowManager, output: URL) async {
        let model = manager.model
        func titles(_ menu: NSMenu) -> String { menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: " | ") }
        print("selftest: main menu \(titles(manager.mainMenu()))")
        print("selftest: playback menu \(titles(manager.playbackMenu()))")
        print("selftest: skins menu \(titles(manager.skinsMenu()))")

        func press(_ key: String, _ modifiers: NSEvent.ModifierFlags = []) {
            _ = manager.handleKey(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: manager.main.window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!)
        }
        let repeatBefore = model.repeatEnabled, shuffleBefore = model.shuffle, timeBefore = manager.timeMode
        press("r")
        press("s")
        press("t", .control)
        let keysOK = model.repeatEnabled != repeatBefore && model.shuffle != shuffleBefore && manager.timeMode != timeBefore
        press("r")
        press("s")
        press("t", .control)
        print("selftest: keys R S Ctrl+T: \(keysOK ? "ok" : "FAIL")")

        let tones = [(660.0, "short-a"), (880.0, "short-b")].compactMap { makeTone(frequency: $0.0, name: $0.1, seconds: 1.5) }
        model.load(tones, play: true)
        await wait("now playing") { model.status == .playing && model.elapsed > 0.2 }
        manager.nowPlaying.update()
        print("selftest: now playing \(manager.nowPlaying.summary)")
        model.fadeOutAndStop()
        await wait("stop with fadeout", seconds: 4) { model.status == .stopped }
        print("selftest: volume after the fade \(abs(model.engine.volume - model.volume) < 0.001 ? "restored" : "FAIL")")
        model.play(trackAt: 0)
        await wait("playing again") { model.status == .playing && model.elapsed > 0.1 }
        model.stopsAfterCurrent = true
        await wait("stop after current", seconds: 5) { model.status == .stopped }
        print("selftest: stopped after current at index \(model.currentIndex ?? -1) (expect 0)")

        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let installed = SkinLibrary.install(repository.appendingPathComponent("skins/winamp.wsz"))
        print("selftest: skins installed=\(SkinLibrary.installed().map(SkinLibrary.name)) thumbnail=\(SkinLibrary.thumbnail(of: installed) != nil ? "ok" : "FAIL")")
        (NSApp.delegate as? AppDelegate)?.showSkinBrowser(nil)
        try? await Task.sleep(for: .milliseconds(1500))  // thumbnails render in the background
        if let browser = NSApp.windows.first(where: { $0.title == "Skins" }), let view = browser.contentView {
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("skin-browser.png"))
            }
            browser.close()
        }
    }

    /// The layout comes back as it was saved: positions, shade, sizes, visibility.
    private static func layoutSteps(_ manager: WindowManager) {
        manager.saveLayout()
        let saved = layout(manager)
        manager.equalizer.shade.toggle()
        manager.nudgeForTesting(.playlist, dx: 40, dy: 30)
        manager.render()
        let disturbed = layout(manager)
        manager.applySavedLayout()
        manager.render()
        let restored = layout(manager)
        print("selftest: layout restored: \(restored == saved && disturbed != saved ? "ok" : "MISMATCH")")
        if restored != saved { print("selftest: saved    \(saved)\nselftest: restored \(restored)") }
    }

    /// preferences-<tab><suffix>.png per tab; the window must fit each tab's content.
    private static func snapPreferences(to folder: URL, tabs: [PreferencesWindowController.Tab], suffix: String = "") async {
        for tab in tabs {
            (NSApp.delegate as? AppDelegate)?.showPreferences(tab: tab)
            try? await Task.sleep(for: .milliseconds(400))  // the window resizes to the tab
            guard let prefs = NSApp.windows.first(where: { $0.identifier == PreferencesWindowController.identifier }),
                let view = prefs.contentView
            else { continue }
            view.layoutSubtreeIfNeeded()
            let fits = view.fittingSize.height <= view.frame.height + 1
            print("selftest: preferences \(tab.title): title=\(prefs.title) size=\(view.frame.size) fits: \(fits ? "ok" : "CLIPPED (needs \(view.fittingSize))")")
            if let image = capture(prefs) {
                let name = "preferences-\(tab.title.lowercased())\(suffix).png"
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
            }
        }
        NSApp.windows.first { $0.identifier == PreferencesWindowController.identifier }?.close()
    }

    /// A window as the window server shows it: title bar, toolbar and Metal layers included.
    static func capture(_ window: NSWindow) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
    }

    private static func wait(_ what: String, seconds: Double = 8, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        print("selftest: \(what): \(done() ? "ok" : "TIMEOUT")")
    }

    /// The local library: tagged FLAC files in a folder, scanned, browsed, searched and played.
    private static func localLibrarySteps(_ manager: WindowManager, snap: (String) -> Void) async {
        let music = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-selftest-music")
        try? FileManager.default.removeItem(at: music)
        let tracks: [(path: String, title: String, artist: String, album: String, number: Int)] = [
            ("Delta/Dawn/01 Morning.flac", "Morning", "Delta", "Dawn", 1),
            ("Delta/Dawn/02 Noon.flac", "Noon", "Delta", "Dawn", 2),
            ("Echo/Evening/01 Dusk.flac", "Dusk", "Echo", "Evening", 1),
        ]
        for (i, track) in tracks.enumerated() {
            let url = music.appendingPathComponent(track.path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let wav = makeTone(frequency: 440 + Double(i) * 110, name: "library-\(i)", seconds: 2) else { continue }
            try? AudioConverter.convert(wav, to: url)
            if let file = try? AudioFile(readingPropertiesAndMetadataFrom: url) {
                file.metadata.title = track.title
                file.metadata.artist = track.artist
                file.metadata.albumTitle = track.album
                file.metadata.trackNumber = track.number
                try? file.writeMetadata()
            }
        }

        let model = manager.model, service = manager.localLibraryService, library = manager.localLibrary
        manager.toggleLocalLibrary()
        await wait("local library empty") { library.summary.contains("No folders") }
        snap("local-empty")
        service.setFolders([music])
        await wait("local library scanned") { library.summary.contains("artists=2") && service.progress == nil }
        print("selftest: local \(library.summary)")
        snap("local-artists")
        // A file added to a watched folder shows up on its own.
        let added = music.appendingPathComponent("Foxtrot/First/01 One.flac")
        try? FileManager.default.createDirectory(at: added.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let wav = makeTone(frequency: 550, name: "library-new", seconds: 1) {
            try? AudioConverter.convert(wav, to: added)
            if let file = try? AudioFile(readingPropertiesAndMetadataFrom: added) {
                file.metadata.title = "One"
                file.metadata.artist = "Foxtrot"
                file.metadata.albumTitle = "First"
                try? file.writeMetadata()
            }
        }
        await wait("local library noticed a new file", seconds: 20) { library.summary.contains("artists=3") }
        library.selectForTesting(row: 0, in: 0)
        library.selectForTesting(row: 0, in: 0)
        await wait("local artist") { library.summary.contains("albums=1 ") && library.summary.contains("songs=2 ") }
        print("selftest: local \(library.summary)")
        snap("local-artist")
        library.searchForTesting("dusk")
        await wait("local search") { library.summary.contains("songs=1 ") && library.summary.contains("artists=0 ") }
        print("selftest: local \(library.summary)")
        library.searchForTesting("")
        library.chooseViewForTesting(1)
        await wait("local recently added") { library.summary.contains("view=Recently Added") && library.summary.contains("albums=3 ") }
        library.selectForTesting(row: 0, in: 0)
        await wait("recent album tracks") { library.summary.contains("songs=") && !library.summary.contains("songs=0 ") }
        library.playAllForTesting()
        await wait("local playing") { model.status == .playing && model.elapsed > 0.2 }
        print("selftest: local playing \(model.displayedTrack?.displayName ?? "-") of \(model.playlist.count)")
        snap("local-playing")
        model.stop()
        manager.toggleLocalLibrary()
    }

    private static func navidromeSteps(_ manager: WindowManager, snap: (String) -> Void) async {
        let server = ProcessInfo.processInfo.environment["HAGTAMP_SELFTEST_NAVIDROME"].flatMap(URL.init(string:))
            ?? URL(string: "http://localhost:4533")!
        guard (try? await NavidromeService.test(url: server, username: "admin", password: "admin")) != nil else {
            print("selftest: navidrome: local server not running, skipped")
            return
        }
        let model = manager.model, library = manager.navidromeLibrary
        manager.navidrome.configure(url: server, username: "admin", password: "admin")
        let credentialsFile = Storage.supportDirectory.appendingPathComponent("credentials.json")
        let saved = (try? String(contentsOf: credentialsFile, encoding: .utf8)) ?? ""
        let permissions = (try? FileManager.default.attributesOfItem(atPath: credentialsFile.path)[.posixPermissions] as? Int) ?? 0
        print("selftest: navidrome login saved as a token: \(saved.contains("token") && !saved.contains("password") ? "ok" : "FAIL") permissions=\(String(permissions, radix: 8))")
        manager.toggleNavidromeLibrary()
        func wait(_ what: String, seconds: Double = 8, until done: () -> Bool) async {
            await SelfTest.wait("navidrome \(what)", seconds: seconds, until: done)
        }
        await wait("artists") { library.summary.contains("artists=2") }
        print("selftest: library \(library.summary)")
        snap("library-artists")

        library.selectForTesting(row: 0, in: 0)
        await wait("artist albums and songs") { library.summary.contains("albums=2") && library.summary.contains("songs=6") }
        print("selftest: library \(library.summary)")
        snap("library-artist")

        // Other views through the sidebar, and a search typed on the keyboard.
        func clickSidebar(_ row: Int) {
            let point = SkinPoint(x: 30, y: 20 + row * 13 + 6)
            library.mouseDown(at: point, event: event(.leftMouseDown, library))
            library.mouseUp(at: point, event: event(.leftMouseUp, library))
        }
        // Favourites: star an album and a song on the server, list them, unstar them again.
        if let client = manager.navidrome.client, let albums = try? await client.albumList(.alphabeticalByName), albums.count > 1,
            let song = try? await client.album(albums[0].id).song?.first
        {
            try? await client.setStarred(true, .album(albums[1].id))
            try? await client.setStarred(true, .song(song.id))
            clickSidebar(1)
            await wait("favourites") {
                library.summary.contains("view=Favourites") && library.summary.contains("albums=1 ") && library.summary.contains("songs=1 ")
            }
            print("selftest: library \(library.summary)")
            snap("library-favourites")
            try? await client.setStarred(false, .album(albums[1].id))
            try? await client.setStarred(false, .song(song.id))
            clickSidebar(1)  // clicking again refreshes
            await wait("favourites refreshed") { library.summary.contains("albums=0 ") && library.summary.contains("songs=0 ") }
        }
        clickSidebar(2)
        await wait("recently added") { library.summary.contains("albums=4") }
        // Keep offline: the album's songs download and stay; the row gets its dot.
        library.setKeptOfflineForTesting(list: 0, row: 0, true)
        let navidrome = manager.navidrome
        await wait("kept offline", seconds: 30) {
            navidrome.offlineProgress == nil && !(navidrome.offlinePins.first?.songIDs.isEmpty ?? true)
                && navidrome.offlinePins.first!.songIDs.allSatisfy { navidrome.cachedFile(for: NavidromeTrack.url(songID: $0)) != nil }
        }
        let folder = navidrome.offlinePins.first?.songIDs.first.flatMap { navidrome.cachedFile(for: NavidromeTrack.url(songID: $0)) }?.deletingLastPathComponent().lastPathComponent
        print("selftest: offline \(navidrome.offlinePins.map { "\($0.name): \($0.songIDs.count) songs" }) in=\(folder ?? "-") menu=\(library.contextMenuTitlesForTesting(list: 0, row: 0))")
        library.setKeptOfflineForTesting(list: 0, row: 0, false)
        clickSidebar(3)
        await wait("playlists") { library.summary.contains("view=Playlists") && !library.summary.contains("Loading") }
        print("selftest: library \(library.summary)")

        // Radio: a station on the server; a song streamed as MP3 stands in for a broadcast.
        if let client = manager.navidrome.client, let album = try? await client.albumList(.alphabeticalByName).first,
            let song = try? await client.album(album.id).song?.first
        {
            let name = "Hagtamp Test FM"
            try? await client.createRadioStation(name: name, streamURL: client.streamURL(songID: song.id, format: "mp3", maxBitRate: 128))
            clickSidebar(4)
            await wait("radio stations") { library.summary.contains("view=Radio") && !library.summary.contains("songs=0 ") }
            print("selftest: library \(library.summary)")
            snap("library-radio")
            library.playAllForTesting()
            await wait("radio playing", seconds: 15) { model.status == .playing && model.buffering == nil && model.elapsed > 0.5 }
            print("selftest: radio playing \(model.displayedTrack?.displayName ?? "-") seekable=\(model.engine.canSeek) duration=\(model.duration ?? -1) marquee=\(manager.marqueeText)")
            model.stop()
            for station in (try? await client.radioStations()) ?? [] where station.name == name {
                try? await client.deleteRadioStation(id: station.id)
            }
        }
        let field = SkinPoint(x: 11 + 96 + 3 + 60, y: 27)
        library.mouseDown(at: field, event: event(.leftMouseDown, library))
        library.mouseUp(at: field, event: event(.leftMouseUp, library))
        for character in "beta" {
            _ = library.keyDown(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: library.window.windowNumber,
                context: nil, characters: String(character), charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0)!)
        }
        _ = library.keyDown(key(36, library))
        await wait("search") { library.summary.contains("artists=1") && library.summary.contains("songs=6") }
        print("selftest: library \(library.summary)")
        snap("library-search")
        clickSidebar(0)
        await wait("library again") { library.summary.contains("artists=2") }
        library.selectForTesting(row: 0, in: 0)
        await wait("artist songs again") { library.summary.contains("songs=6") }

        library.playAllForTesting()
        await wait("buffering done", seconds: 30) { model.buffering == nil && model.status == .playing && model.elapsed > 0.3 }
        // Tone 1 has made-up synced lyrics on the dev server (a .lrc next to it).
        manager.toggleLyrics()
        await wait("server lyrics", seconds: 10) { manager.lyrics.summary.hasPrefix("lines=6 synced=true") }
        print("selftest: navidrome lyrics \(manager.lyrics.summary)")
        manager.toggleLyrics()
        // Not seekable yet means it started as a stream, before the download completed.
        print("selftest: navidrome playing index=\(model.currentIndex ?? -1) status=\(model.status) elapsed=\(String(format: "%.2f", model.elapsed)) seekable=\(model.engine.canSeek) title=\(model.displayedTrack?.displayName ?? "-") marquee=\(manager.marqueeText)")
        // Seeking works once the track is in the cache (a stream can't seek; the cached file takes over).
        let first = model.playlist[0].url
        await wait("first track cached", seconds: 30) { manager.navidrome.cachedFile(for: first) != nil }
        model.seek(to: 0.6)
        await wait("remote seek") { model.currentIndex == 0 && model.elapsed > (model.duration ?? 25) * 0.55 }
        print("selftest: navidrome seek elapsed=\(String(format: "%.2f", model.elapsed)) duration=\(String(format: "%.2f", model.duration ?? -1))")
        let next = model.playlist.count > 1 ? model.playlist[1].url : nil
        await wait("next track prefetched", seconds: 30) { next.flatMap(manager.navidrome.cachedFile(for:)) != nil }
        model.next()
        await wait("next remote track playing") { model.currentIndex == 1 && model.status == .playing && model.buffering == nil && model.elapsed > 0.3 }
        model.next()  // not prefetched yet: buffers, then plays
        await wait("third remote track playing", seconds: 30) { model.currentIndex == 2 && model.status == .playing && model.buffering == nil && model.elapsed > 0.3 }
        print("selftest: navidrome after next index=\(model.currentIndex ?? -1) status=\(model.status) engine=\(model.engine.state) elapsed=\(String(format: "%.2f", model.elapsed))")
        manager.toggleAlbumArt()
        await wait("remote cover") { manager.albumArt.hasCover }
        snap("library-playing")
        manager.toggleAlbumArt()
        model.stop()
        manager.toggleNavidromeLibrary()
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
        let windows = [manager.main, manager.equalizer, manager.playlist, manager.albumArt, manager.navidromeLibrary, manager.localLibrary, manager.lyrics, manager.visualization].filter { $0.window.isVisible }
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
        [("main", manager.main), ("eq", manager.equalizer), ("pl", manager.playlist), ("art", manager.albumArt), ("nd", manager.navidromeLibrary), ("local", manager.localLibrary), ("lyrics", manager.lyrics), ("vis", manager.visualization)].map { name, c in
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
