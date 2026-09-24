import AppKit
import AudioCore
import ClassicUI
import PlayerCore
import SkinKit
import UniformTypeIdentifiers

/// Owns the three classic windows: renders them, keeps docked windows
/// together, and holds the UI state shared between windows (double size,
/// always on top, time mode, marquee).
@MainActor
final class WindowManager: NSObject {
    let model: PlayerModel
    let navidrome: NavidromeService
    let localLibraryService: LocalLibraryService
    let cursors = CursorController()
    private(set) var skin: Skin
    var onSkinChange: ((Skin) -> Void)?

    private(set) var doubleSize = false
    private(set) var alwaysOnTop = false
    var timeMode = TimeDisplayMode.elapsed {
        didSet { saveLayout() }
    }
    /// Text in the playlist, library lists and lyrics (Preferences; Winamp's is 1x).
    var textSize = TextSize(scale: Storage.defaults.object(forKey: "textScale") as? Double ?? 1.5) {
        didSet {
            Storage.defaults.set(textSize.scale, forKey: "textScale")
            render()
        }
    }

    private(set) lazy var main = MainWindowController(manager: self)
    private(set) lazy var equalizer = EqualizerWindowController(manager: self)
    private(set) lazy var playlist = PlaylistWindowController(manager: self)
    private(set) lazy var albumArt = AlbumArtWindowController(manager: self)
    private(set) lazy var navidromeLibrary = LibraryWindowController(id: .navidromeLibrary, source: navidrome, manager: self)
    private(set) lazy var localLibrary = LibraryWindowController(id: .localLibrary, source: localLibraryService, manager: self)
    private(set) lazy var lyrics = LyricsWindowController(manager: self)
    private(set) lazy var visualization = VisualizationWindowController(manager: self)
    private var controllers: [SkinWindowController] {
        [main, equalizer, playlist, albumArt, navidromeLibrary, localLibrary, lyrics, visualization]
    }
    /// Where extra windows kept their visibility before the saved layout
    /// (read once, when there is no layout yet).
    private static let visibilityKeys: [WindowID: String] = [
        .albumArt: "albumArtVisible", .navidromeLibrary: "mediaLibraryVisible", .localLibrary: "localLibraryVisible",
    ]
    private var visible: Set<WindowID> = {
        var ids: Set<WindowID> = [.main, .equalizer, .playlist]
        for (id, key) in WindowManager.visibilityKeys where Storage.defaults.bool(forKey: key) { ids.insert(id) }
        return ids
    }()

    private var uiTimer: Timer?
    private var displayLink: CADisplayLink?

    // MARK: Visualizer state
    private let visualizer = Visualizer()
    /// Latest frame shown in the main window; nil shows the skin's background.
    private(set) var visualizerFrame: Bitmap?
    var visualizerSettings = VisualizerSettings() {
        didSet {
            Storage.defaults.set(try? JSONEncoder().encode(visualizerSettings), forKey: "visualizer")
            if visualizerSettings.mode == .off { visualizerFrame = nil }
            renderMain()
        }
    }
    private var move: (start: NSPoint, moving: [WindowBox], stationary: [WindowBox])?
    private(set) lazy var nowPlaying = NowPlaying(model: model) { [weak self] url in await self?.cover(for: url) }

    init(model: PlayerModel, skin: Skin, navidrome: NavidromeService, localLibrary: LocalLibraryService) {
        self.model = model
        self.skin = skin
        self.navidrome = navidrome
        self.localLibraryService = localLibrary
        super.init()
        cursors.load(skin)
        model.onChange = { [weak self] in self?.playerChanged() }
        if let data = Storage.defaults.data(forKey: "visualizer"),
            let saved = try? JSONDecoder().decode(VisualizerSettings.self, from: data)
        {
            visualizerSettings = saved
        }
    }

    var scale: Int { doubleSize ? 2 : 1 }

    func controller(_ id: WindowID) -> SkinWindowController {
        switch id {
        case .main: main
        case .equalizer: equalizer
        case .playlist: playlist
        case .albumArt: albumArt
        case .navidromeLibrary: navidromeLibrary
        case .localLibrary: localLibrary
        case .lyrics: lyrics
        case .visualization: visualization
        }
    }

    // MARK: - Lifecycle

    /// Puts the windows back as they were at the last quit, or in Winamp's
    /// default layout (stacked, extra windows docked to the right of the
    /// main window), and shows them.
    func start() {
        applySavedLayout()
        started = true
        render()
        for c in controllers.reversed() where visible.contains(c.id) { c.window.orderFront(nil) }
        main.window.makeKeyAndOrderFront(nil)

        let timer = Timer(timeInterval: Marquee.stepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.uiTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer

        let link = main.window.skinView.displayLink(target: self, selector: #selector(visualizerTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        #if DEBUG
        DispatchQueue.main.async { SelfTest.runIfRequested(self) }
        #endif
    }

    func setSkin(_ skin: Skin) {
        self.skin = skin
        cursors.load(skin)
        render()
        onSkinChange?(skin)
    }

    // MARK: - Rendering

    /// Re-renders every visible window. Size changes (shade, double size,
    /// resize) move docked windows along with the edges they are attached to.
    func render() {
        var bitmaps: [WindowID: Bitmap] = [:]
        var sizes: [WindowID: (width: Int, height: Int)] = [:]
        for c in controllers where visible.contains(c.id) {
            let bitmap = c.renderMasked()
            bitmaps[c.id] = bitmap
            sizes[c.id] = (bitmap.width * scale, bitmap.height * scale)
        }
        let boxes = visibleBoxes()
        let resized = boxes.contains { box in
            sizes[box.id].map { $0.width != box.width || $0.height != box.height } ?? false
        }
        if resized {
            for box in WindowDocking.reflow(boxes, newSizes: sizes) {
                setFrame(controller(box.id), box)
            }
        }
        for (id, bitmap) in bitmaps {
            controller(id).window.skinView.show(bitmap)
        }
    }

    /// Re-renders only the main window (visualizer frames).
    func renderMain() {
        guard isVisible(.main) else { return }
        main.window.skinView.show(main.renderMasked())
    }

    @objc private func visualizerTick() {
        guard visualizerSettings.mode != .off, isVisible(.main) else { return }
        switch model.status {
        case .playing:
            visualizerFrame = visualizer.render(
                samples: model.engine.samples.latest(1024), colors: skin.visColors,
                settings: visualizerSettings, small: main.shade)
            renderMain()
        case .paused:
            break  // the last frame stays up
        case .stopped:
            if visualizerFrame != nil {
                visualizerFrame = nil
                renderMain()
            }
        }
    }

    @objc func cycleVisualizer() {
        visualizerSettings.mode = visualizerSettings.nextMode
    }

    /// Winamp's visualization options (right-click on the visualizer, clutter bar "V").
    func showVisualizerMenu(for event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(visualizerMenu(), with: event, for: view)
    }

    func visualizerMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = visualizerSettings
        func choice<T: Equatable>(_ title: String, _ value: T, _ keyPath: WritableKeyPath<VisualizerSettings, T>) -> NSMenuItem {
            NSMenuItem(title: title, checked: settings[keyPath: keyPath] == value) { [weak self] in
                self?.visualizerSettings[keyPath: keyPath] = value
            }
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            items.forEach { item.submenu?.addItem($0) }
            return item
        }
        let falloffTitles: [(String, VisualizerSettings.Falloff)] = [
            ("Slowest", .slower), ("Slow", .slow), ("Moderate", .moderate), ("Fast", .fast), ("Fastest", .faster),
        ]
        menu.addItem(submenu("Visualization mode", [
            choice("Spectrum analyzer", .analyzer, \.mode),
            choice("Oscilloscope", .oscilloscope, \.mode),
            choice("Disabled", .off, \.mode),
        ]))
        menu.addItem(submenu("Analyzer options", [
            choice("Normal style", .normal, \.analyzerStyle),
            choice("Fire style", .fire, \.analyzerStyle),
            choice("Line style", .line, \.analyzerStyle),
            .separator(),
            choice("Thick bands", .thick, \.bandWidth),
            choice("Thin bands", .thin, \.bandWidth),
            .separator(),
            NSMenuItem(title: "Show peaks", checked: settings.peaks) { [weak self] in self?.visualizerSettings.peaks.toggle() },
        ]))
        menu.addItem(submenu("Oscilloscope options", [
            choice("Dot scope", .dots, \.oscilloscopeStyle),
            choice("Line scope", .lines, \.oscilloscopeStyle),
            choice("Solid scope", .solid, \.oscilloscopeStyle),
        ]))
        menu.addItem(submenu("Analyzer falloff", falloffTitles.map { choice($0.0, $0.1, \.barFalloff) }))
        menu.addItem(submenu("Peaks falloff", falloffTitles.map { choice($0.0, $0.1, \.peakFalloff) }))
        return menu
    }

    private func playerChanged() {
        if model.status == .paused, pausedSince == nil { pausedSince = Date() }
        if model.status != .paused { pausedSince = nil }
        render()
        nowPlaying.update()
    }

    // MARK: - Windows

    func isVisible(_ id: WindowID) -> Bool { visible.contains(id) }

    func setVisible(_ id: WindowID, _ show: Bool) {
        defer {
            controller(id).visibilityChanged(show)
            saveLayout()
        }
        let c = controller(id)
        if show {
            visible.insert(id)
            // Keep the top-left corner; the size may have changed while hidden (double size).
            let box = self.box(c)
            let (w, h) = c.pixelSize()
            setFrame(c, WindowBox(id, x: box.x, y: box.y, width: w * scale, height: h * scale))
            c.window.orderFront(nil)
        } else {
            visible.remove(id)
            c.window.orderOut(nil)
        }
        render()
    }

    func toggleShade(_ id: WindowID) {
        controller(id).shade.toggle()
        render()
        saveLayout()
    }

    @objc func toggleDoubleSize() {
        doubleSize.toggle()
        render()
        saveLayout()
    }

    @objc func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        for c in controllers { c.window.level = alwaysOnTop ? .floating : .normal }
        render()
        saveLayout()
    }

    @objc func toggleEqualizer() { setVisible(.equalizer, !isVisible(.equalizer)) }

    @objc func toggleAlbumArt() { toggleExtra(albumArt) }
    @objc func toggleNavidromeLibrary() { toggleExtra(navidromeLibrary) }
    @objc func toggleLocalLibrary() { toggleExtra(localLibrary) }
    @objc func toggleVisualization() { toggleExtra(visualization) }

    @objc func toggleLyrics() {
        if !isVisible(.lyrics) { lyrics.reloadMissing() }
        toggleExtra(lyrics)
    }

    func hideLibrary(_ library: LibraryWindowController) {
        hideExtra(library)
    }

    func hideExtra(_ c: SkinWindowController) {
        if isVisible(c.id) { toggleExtra(c) }
    }

    /// Shows or hides a window beyond the classic three, placing it on first showing.
    private func toggleExtra(_ c: SkinWindowController) {
        let show = !isVisible(c.id)
        // Never shown, or last left where it can't be grabbed (off a screen's edge, a screen gone).
        if show && (!c.window.isPlaced || !WindowDocking.isReachable(box(c), screens: screenBoxes())) { placeBesideMain(c) }
        setVisible(c.id, show)
        if show && (c is LibraryWindowController || c is VisualizationWindowController) { c.window.makeKey() }
    }

    /// First showing of an extra window: docked to the right of the main
    /// window, after any windows already there.
    private func placeBesideMain(_ c: SkinWindowController) {
        let (w, h) = c.pixelSize()
        setFrame(c, WindowDocking.placement(
            c.id, width: w * scale, height: h * scale, main: box(main), others: visibleBoxes(), screens: screenBoxes()))
    }
    @objc func togglePlaylist() { setVisible(.playlist, !isVisible(.playlist)) }

    /// Brings all visible windows above other apps' windows, keeping their
    /// order among themselves, with `id` on top. Winamp raises all its windows
    /// together; macOS only raises the window that was clicked.
    func raiseAll(keepingOnTop id: WindowID) {
        let top = controller(id).window
        let ours = Set(controllers.filter { visible.contains($0.id) }.map { ObjectIdentifier($0.window) })
        let frontToBack = NSApp.orderedWindows.filter { ours.contains(ObjectIdentifier($0)) }
        for window in frontToBack.reversed() where window !== top {
            window.orderFront(nil)
        }
        top.orderFront(nil)
    }

    // MARK: - Moving windows

    func beginMove(_ id: WindowID, from mouse: NSPoint = NSEvent.mouseLocation) {
        let boxes = visibleBoxes()
        let group = WindowDocking.movingGroup(dragging: id, windows: boxes)
        move = (mouse, boxes.filter { group.contains($0.id) }, boxes.filter { !group.contains($0.id) })
    }

    func continueMove(to now: NSPoint = NSEvent.mouseLocation) {
        guard let move else { return }
        let dx = Int((now.x - move.start.x).rounded()), dy = Int((move.start.y - now.y).rounded())
        let offset = WindowDocking.snappedOffset(
            moving: move.moving, stationary: move.stationary, screens: screenBoxes(), dx: dx, dy: dy)
        for box in move.moving {
            setFrame(controller(box.id), box.offsetBy(dx: offset.dx, dy: offset.dy))
        }
    }

    func endMove() {
        move = nil
        saveLayout()
    }

    /// Resizes a window keeping its top-left corner, moving docked windows along.
    func windowSizeChanged() {
        render()
        saveLayout()
    }

    // MARK: - Layout between launches

    /// Windows and their modes as the user left them.
    private struct Layout: Codable {
        struct Window: Codable {
            /// Top-left corner in global top-left coordinates; nil if never shown.
            var x: Int?
            var y: Int?
            var visible: Bool
            var shade: Bool
            var state: [String: Int]
        }

        var windows: [String: Window]
        var doubleSize: Bool
        var alwaysOnTop: Bool
        var timeRemaining: Bool
    }

    private static let layoutKey = "windowLayout"
    /// Nothing is saved until the saved layout has been applied.
    private var started = false

    func saveLayout() {
        guard started else { return }
        var windows: [String: Layout.Window] = [:]
        for c in controllers {
            let placed = c.window.isPlaced
            let b = box(c)
            windows[c.id.rawValue] = Layout.Window(
                x: placed ? b.x : nil, y: placed ? b.y : nil, visible: visible.contains(c.id), shade: c.shade,
                state: c.savedState())
        }
        let layout = Layout(windows: windows, doubleSize: doubleSize, alwaysOnTop: alwaysOnTop, timeRemaining: timeMode == .remaining)
        Storage.defaults.set(try? JSONEncoder().encode(layout), forKey: Self.layoutKey)
    }

    /// The saved layout (modes first, then positions), moved back onto the
    /// screens if a monitor is gone; windows without a place get Winamp's defaults.
    func applySavedLayout() {
        let layout = Storage.defaults.data(forKey: Self.layoutKey).flatMap { try? JSONDecoder().decode(Layout.self, from: $0) }
        if let layout {
            doubleSize = layout.doubleSize
            alwaysOnTop = layout.alwaysOnTop
            timeMode = layout.timeRemaining ? .remaining : .elapsed
            visible = [.main]
            for c in controllers {
                c.window.level = alwaysOnTop ? .floating : .normal
                guard let saved = layout.windows[c.id.rawValue] else { continue }
                c.shade = saved.shade
                c.restore(saved.state)
                if saved.visible { visible.insert(c.id) }
            }
        }

        var saved: [WindowBox] = []
        for c in controllers {
            guard let window = layout?.windows[c.id.rawValue], let x = window.x, let y = window.y else { continue }
            let (w, h) = c.pixelSize()
            saved.append(WindowBox(c.id, x: x, y: y, width: w * scale, height: h * scale))
        }
        let home = defaultOrigin()
        let restored = WindowDocking.restore(saved, screens: screenBoxes(), home: home)
        var placed = Set<WindowID>()
        for box in restored.placed {
            setFrame(controller(box.id), box)
            placed.insert(box.id)
        }
        // Defaults: the classic three stacked from `home`, the rest beside the main window.
        var y = home.y
        for c in [main, equalizer, playlist] as [SkinWindowController] {
            let (w, h) = c.pixelSize()
            if !placed.contains(c.id) || !placed.contains(.main) {
                setFrame(c, WindowBox(c.id, x: home.x, y: y, width: w * scale, height: h * scale))
            }
            y = box(c).bottom
        }
        for c in [albumArt, navidromeLibrary, localLibrary, lyrics, visualization] as [SkinWindowController]
        where visible.contains(c.id) && (!placed.contains(c.id) || !placed.contains(.main)) {
            placeBesideMain(c)
        }
        for c in controllers where visible.contains(c.id) { c.visibilityChanged(true) }
        for c in controllers where !visible.contains(c.id) { c.window.orderOut(nil) }
    }

    #if DEBUG
    /// Self test: moves a window without saving the layout.
    func nudgeForTesting(_ id: WindowID, dx: Int, dy: Int) {
        let c = controller(id)
        setFrame(c, box(c).offsetBy(dx: dx, dy: dy))
    }
    #endif

    private func defaultOrigin() -> (x: Int, y: Int) {
        let frame = NSScreen.main?.visibleFrame ?? .zero
        return (Int(frame.minX) + 80, Int(Self.primaryMaxY - frame.maxY) + 80)
    }

    // MARK: - Coordinates (global, top-left origin)

    private static var primaryMaxY: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    private func box(_ c: SkinWindowController) -> WindowBox {
        let f = c.window.frame
        return WindowBox(
            c.id, x: Int(f.minX.rounded()), y: Int((Self.primaryMaxY - f.maxY).rounded()),
            width: Int(f.width.rounded()), height: Int(f.height.rounded()))
    }

    private func setFrame(_ c: SkinWindowController, _ box: WindowBox) {
        let frame = NSRect(
            x: CGFloat(box.x), y: Self.primaryMaxY - CGFloat(box.y + box.height),
            width: CGFloat(box.width), height: CGFloat(box.height))
        if c.window.frame != frame { c.window.setFrame(frame, display: true) }
        c.window.isPlaced = true
    }

    private func visibleBoxes() -> [WindowBox] {
        controllers.filter { visible.contains($0.id) }.map(box)
    }

    private func screenBoxes() -> [WindowBox] {
        NSScreen.screens.map { screen in
            let f = screen.visibleFrame
            return WindowBox(
                .main, x: Int(f.minX), y: Int(Self.primaryMaxY - f.maxY), width: Int(f.width), height: Int(f.height))
        }
    }

    // MARK: - Covers

    /// A track's cover: Navidrome's, or from the file's folder or tags (read off the main thread).
    func cover(for url: URL) async -> NSImage? {
        if navidrome.handles(url) { return await navidrome.cover(for: url) }
        guard url.isFileURL else { return nil }
        let data = await Task.detached(priority: .utility) { CoverArt.imageData(for: url) }.value
        return data.flatMap(NSImage.init(data:))
    }

    // MARK: - Lyrics

    /// A track's lyrics: Navidrome's (plugins included), or a local .lrc / lyrics tag.
    func lyrics(for track: TrackInfo) async -> Lyrics? {
        if navidrome.handles(track.url) { return await navidrome.lyrics(for: track) }
        guard track.url.isFileURL else { return nil }
        let url = track.url
        return await Task.detached(priority: .utility) { Lyrics.local(for: url) }.value
    }

    // MARK: - Marquee and blinking

    #if DEBUG
    /// Screenshots show the title from its start.
    func restartMarqueeForTesting() {
        marqueeStep = 0
        render()
    }
    #endif

    /// Temporary text while a slider is dragged ("Volume: 78%").
    var marqueeMessage: String? {
        didSet { if marqueeMessage != oldValue { render() } }
    }

    private var marqueeStep = 0
    private var marqueeDragBase = 0
    private var marqueeDragLive = 0
    private var marqueeDragging = false
    private var marqueeResumeAt = Date.distantPast
    private var marqueeTrackText = ""
    private var pausedSince: Date?

    /// Shown by the marquee when nothing is loaded.
    static let idleTitle = "Hagtamp " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")

    var marqueeText: String {
        if let marqueeMessage { return marqueeMessage }
        if let buffering = model.buffering { return "Buffering: \(Int(buffering * 100))%" }
        guard let track = model.displayedTrack else { return Self.idleTitle }
        let length = model.duration.map { " (\(Marquee.timeString(Int($0))))" } ?? ""
        let number = model.currentIndex.map { "\($0 + 1). " } ?? ""
        return "\(number)\(track.displayName)\(length)"
    }

    var marqueeOffset: Int {
        Marquee.offset(for: marqueeText, step: marqueeStep, dragPixels: marqueeDragBase + marqueeDragLive)
    }

    func beginMarqueeDrag() {
        marqueeDragging = true
    }

    /// `pixels`: pointer movement since the drag began (the text follows the pointer).
    func dragMarquee(by pixels: Int) {
        marqueeDragLive = -pixels
        render()
    }

    func endMarqueeDrag() {
        marqueeDragBase += marqueeDragLive
        marqueeDragLive = 0
        marqueeDragging = false
        // Winamp resumes scrolling a moment after the drag.
        marqueeResumeAt = Date().addingTimeInterval(1)
    }

    /// Paused time blinks: one second on, one second off.
    var timeVisible: Bool {
        guard let pausedSince else { return true }
        return Int(Date().timeIntervalSince(pausedSince)) % 2 == 0
    }

    private func uiTick() {
        model.savePosition()
        navidrome.updateScrobbling(
            url: model.nowPlayingURL, playing: model.status == .playing && model.buffering == nil,
            elapsed: model.elapsed, duration: model.duration)
        let text = marqueeText
        if text != marqueeTrackText, marqueeMessage == nil {
            marqueeTrackText = text
            marqueeStep = 0
            marqueeDragBase = 0
        }
        if !marqueeDragging, marqueeMessage == nil, Date() >= marqueeResumeAt, Marquee.scrolls(text) {
            marqueeStep += 1
        }
        render()
    }

    // MARK: - Menus and keys

    /// Winamp's keys: Z X C V B, L, J, R, S, arrows, the keypad and the
    /// Ctrl/Shift/Alt combinations from its menus.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (flags, key) {
        case ([], "z"): model.previous()
        case ([], "x"): model.play()
        case ([], "c"): model.pause()
        case ([], "v"): model.stop()
        case ([], "b"): model.next()
        case ([], "l"): openFiles()
        case ([], "j"): showJumpToFile()
        case ([], "r"): model.repeatEnabled.toggle()
        case ([], "s"): model.shuffle.toggle()
        case ([.shift], "v"): model.fadeOutAndStop()
        case ([.control], "v"): model.stopsAfterCurrent.toggle()
        case ([.control], "z"): model.startOfList()
        case ([.control], "l"): playURL()
        case ([.control], "j"): jumpToTime()
        case ([.control], "t"): timeMode = timeMode == .elapsed ? .remaining : .elapsed
        case ([.control], "d"): toggleDoubleSize()
        case ([.control], "a"): toggleAlwaysOnTop()
        case ([.control], "p"): (NSApp.delegate as? AppDelegate)?.showPreferences(nil)
        case ([.option], "s"): (NSApp.delegate as? AppDelegate)?.showSkinBrowser(nil)
        case ([.control, .shift], "k"): toggleVisualization()
        default:
            guard flags.isEmpty || flags == [.shift] else { return false }
            switch event.keyCode {
            case 126: model.volume = min(1, model.volume + 0.02)
            case 125: model.volume = max(0, model.volume - 0.02)
            case 123: seek(bySeconds: -5)
            case 124: seek(bySeconds: 5)
            case 83: model.skip(tracks: -10)  // keypad 1
            case 85: model.skip(tracks: 10)  // keypad 3
            default: return false
            }
        }
        return true
    }


    func seek(bySeconds seconds: Double) {
        guard let duration = model.duration, duration > 0 else { return }
        model.seek(to: (model.elapsed + seconds) / duration)
    }

    /// Skins are applied; audio and playlist files replace the playlist and
    /// play, or are inserted where they were dropped on the playlist.
    func filesDropped(_ urls: [URL], on id: WindowID, at point: SkinPoint? = nil) {
        if urls.count == 1, let url = urls.first, Self.isSkin(url) {
            (NSApp.delegate as? AppDelegate)?.loadSkin(from: url)
            return
        }
        guard !PlayerModel.tracks(from: urls).isEmpty else { return }
        if id == .playlist, !playlist.shade {
            model.add(urls, at: point.map(playlist.insertionRow(at:)))
        } else {
            model.load(urls, play: true)
        }
    }

    static func isSkin(_ url: URL) -> Bool {
        if ["wsz", "zip"].contains(url.pathExtension.lowercased()) { return true }
        guard url.hasDirectoryPath else { return false }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return files.contains { $0.lowercased() == "main.bmp" }
    }

    /// Audio files among `urls`, folders expanded recursively in name order.
    static func audioFiles(in urls: [URL]) -> [URL] {
        let extensions = TrackInfo.supportedExtensions
        var result: [URL] = []
        for url in urls {
            if url.hasDirectoryPath {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
                let found = (enumerator?.allObjects as? [URL] ?? [])
                    .filter { extensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                result += found
            } else if extensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }

    /// Winamp's "Play file(s)": replaces the playlist and plays.
    @objc func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = TrackInfo.supportedExtensions.union(PlaylistFile.extensions).compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose files or folders to play"
        guard panel.runModal() == .OK else { return }
        if !PlayerModel.tracks(from: panel.urls).isEmpty { model.load(panel.urls, play: true) }
    }

    private lazy var jumpToFile = JumpToFilePanel(model: model)

    /// Winamp's "Jump to file" (J): search the playlist and play a match.
    @objc func showJumpToFile() {
        jumpToFile.show()
    }
}
