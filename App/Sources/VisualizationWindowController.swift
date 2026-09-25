import AppKit
import AudioCore
import ClassicUI
import Metal
import os
import Milkdrop
import MilkdropMetal
import QuartzCore
import SkinKit

/// The visualization window: MilkDrop-style presets drawn with Metal in a
/// generic skinned frame, or full screen. Keys as in MilkDrop: Space or →
/// next preset (blended), ← or Backspace previous, H hard cut, R random
/// order, L keep this preset, P the preset browser, F/Return/double-click
/// full screen, Esc back.
@MainActor
final class VisualizationWindowController: SkinWindowController {
    private var widthSteps = 5
    private var heightSteps = 8
    private var resizeStart: (mouse: NSPoint, width: Int, height: Int)?
    private let metalView: MetalLayerView
    private var renderLoop: VisualizationRenderLoop?
    let library = PresetLibrary()
    private(set) var currentPreset: URL?
    private var history: [URL] = []
    /// Picked by hand: it stays even if it turns out too heavy.
    private var chosenByHand = false
    private lazy var browser = PresetBrowserController(library: library) { [weak self] url in
        self?.show(url, blend: true, byHand: true)
    }
    var random = true
    var locked = false {
        didSet { renderLoop?.setLocked(locked) }
    }
    private var fullScreen: FullScreenVisualization?
    private var shown = false
    private var occlusionObserver: NSObjectProtocol?

    init(manager: WindowManager) {
        let view = MetalLayerView(device: MTLCreateSystemDefaultDevice())
        metalView = view
        super.init(id: .visualization, manager: manager)
        renderLoop = VisualizationRenderLoop(
            layer: view.metalLayer, samples: manager.model.engine.samples,
            onPresetFinished: { [weak self] in self?.next(blend: true) },
            onTooHeavy: { [weak self] in self?.presetTooHeavy() })
        window.skinView.addSubview(view)
        library.onChange = { [weak self] in self?.libraryChanged() }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDrawing() }
        }
    }

    /// Draws only while someone can see it: the window shown and not entirely
    /// covered by others (macOS doesn't composite a covered window, so its
    /// frames would have nowhere to go), or full screen.
    private func updateDrawing() {
        renderLoop?.setPaused(!(fullScreen != nil || (shown && window.occlusionState.contains(.visible))))
    }

    private var width: Int { GenWindowRenderer.baseWidth + widthSteps * 25 }
    private var height: Int { GenWindowRenderer.baseHeight + heightSteps * 29 }
    private var content: PixelRect { GenWindowRenderer.contentRect(width: width, height: height) }

    override func regions() -> [ControlRegion] {
        GenWindowLayout.regions(width: width, height: height) + [ControlRegion(.trackList, content, .press, cursor: .normal)]
    }
    override func pixelSize() -> (width: Int, height: Int) { (width, height) }
    override func titleBarDoubleClicked() {}

    override func savedState() -> [String: Int] {
        ["width": widthSteps, "height": heightSteps, "random": random ? 1 : 0, "locked": locked ? 1 : 0]
    }

    override func restore(_ state: [String: Int]) {
        widthSteps = max(0, state["width"] ?? widthSteps)
        heightSteps = max(0, state["height"] ?? heightSteps)
        random = (state["random"] ?? 1) != 0
        locked = (state["locked"] ?? 0) != 0
    }

    override func renderBitmap() -> Bitmap {
        var frame = GenWindowState(title: "Visualization")
        frame.focused = isFocused
        frame.pressed = pressed
        frame.widthSteps = widthSteps
        frame.heightSteps = heightSteps
        // Not while full screen (the frame also redraws as it loses focus to the full-screen window).
        if metalView.superview === window.skinView {
            let scale = CGFloat(manager.scale)
            metalView.frame = NSRect(
                x: CGFloat(content.x) * scale, y: CGFloat(content.y) * scale,
                width: CGFloat(content.width) * scale, height: CGFloat(content.height) * scale)
        }
        return GenWindowRenderer.render(manager.skin, frame)
    }

    override func visibilityChanged(_ visible: Bool) {
        shown = visible
        if visible, currentPreset == nil { next(blend: false) }
        updateDrawing()
    }

    /// The list arrived or changed (files added or removed, heavy marks).
    private func libraryChanged() {
        if shown, currentPreset == nil { next(blend: false) }
        if browser.isShown { browser.model.reload() }
    }

    // MARK: - Presets

    /// A random preset, or the next by name; presets found too heavy are passed over.
    func next(blend: Bool, announcing: Bool = true) {
        let all = library.presets
        guard !all.isEmpty else { return }
        let url: URL
        if random {
            let candidates = library.candidates
            url = candidates.count > 1 ? candidates.filter { $0 != currentPreset }.randomElement()! : candidates[0]
        } else {
            let start = currentPreset.flatMap { all.firstIndex(of: $0) } ?? -1
            url = (1...all.count).lazy.map { all[(start + $0) % all.count] }.first { !self.library.isHeavy($0) } ?? all[(start + 1) % all.count]
        }
        show(url, blend: blend, announcing: announcing)
    }

    func previous() {
        guard history.count > 1 else { return }
        history.removeLast()
        show(history.removeLast(), blend: true)
    }

    func show(_ url: URL, blend: Bool, byHand: Bool = false, announcing: Bool = true) {
        guard let preset = library.load(url) else { return }
        currentPreset = url
        chosenByHand = byHand
        history.append(url)
        if history.count > 50 { history.removeFirst() }
        renderLoop?.load(preset, blend: blend)
        browser.model.current = url
        if announcing { announce(preset.name) }
    }

    /// The preset keeps missing the display's pace: it is marked, and unless
    /// it was picked by hand (or locked) the next one takes over at once.
    private func presetTooHeavy() {
        guard let url = currentPreset else { return }
        library.markHeavy(url)
        guard !locked, !chosenByHand else { return }
        announce("Too slow, skipped: \(PresetLibrary.name(url))")
        next(blend: false, announcing: false)
    }

    func showBrowser() {
        browser.show(current: currentPreset)
    }

    /// The preset's name shows in the main window's marquee for a moment.
    private func announce(_ text: String) {
        manager.showMessage(text, seconds: 2.5)
    }

    var currentPresetName: String? { currentPreset.map(PresetLibrary.name) }

    var framesDrawn: Int { renderLoop?.framesDrawn ?? 0 }

    #if DEBUG
    /// Self test: the drawing's size in points (the window's content area, or the whole screen).
    var drawingSizeForTesting: CGSize { metalView.bounds.size }
    var contentSizeForTesting: CGSize { CGSize(width: content.width * manager.scale, height: content.height * manager.scale) }

    /// Self test: average brightness (0...255) of the content area as the
    /// window server shows it, which is where a Metal layer can go missing.
    func onScreenBrightnessForTesting() -> Double? {
        guard let shot = SelfTest.capture(window) else { return nil }
        // The content area, drawn into RGBA bytes (the capture's top-left origin, in window points).
        let scale = CGFloat(shot.width) / max(1, window.frame.width)
        let points = CGFloat(manager.scale)
        let crop = CGRect(x: CGFloat(content.x) * points, y: CGFloat(content.y) * points, width: CGFloat(content.width) * points, height: CGFloat(content.height) * points)
        guard let image = shot.cropping(to: crop.applying(CGAffineTransform(scaleX: scale, y: scale)).integral) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, width * height > 0 else { return nil }
        let sum = stride(from: 0, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) + Int(bytes[$1 + 1]) + Int(bytes[$1 + 2]) }
        return Double(sum) / Double(width * height * 3)
    }
    #endif

    // MARK: - Keys and mouse

    override func keyDown(_ event: NSEvent) -> Bool {
        handleVisualizationKey(event) || super.keyDown(event)
    }

    func handleVisualizationKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (49, _), (124, _): next(blend: true)  // space, →
        case (123, _), (51, _): previous()  // ←, backspace
        case (_, "h"): next(blend: false)
        case (_, "r"):
            random.toggle()
            announce(random ? "Random order" : "Presets in order")
            manager.saveLayout()
        case (_, "l"):
            locked.toggle()
            announce(locked ? "Preset locked" : "Preset unlocked")
            manager.saveLayout()
        case (_, "p"): showBrowser()
        case (_, "f"), (36, _), (76, _): toggleFullScreen()
        case (53, _) where fullScreen != nil: toggleFullScreen()  // esc
        default: return false
        }
        return true
    }

    override func buttonClicked(_ control: Control) {
        if control == .close { manager.hideExtra(self) }
    }

    override func pressBegan(_ control: Control, at point: SkinPoint, event: NSEvent) -> Bool {
        if control == .resize {
            resizeStart = (NSEvent.mouseLocation, widthSteps, heightSteps)
            return true
        }
        if control == .trackList, event.clickCount == 2 { toggleFullScreen() }
        return false
    }

    override func pressDragged(_ control: Control, to point: SkinPoint, event: NSEvent) {
        guard control == .resize, let start = resizeStart else { return }
        let now = NSEvent.mouseLocation
        let scale = CGFloat(manager.scale)
        let dx = (now.x - start.mouse.x) / scale, dy = (start.mouse.y - now.y) / scale
        let newWidth = max(0, start.width + Int((dx / 25).rounded()))
        let newHeight = max(0, start.height + Int((dy / 29).rounded()))
        guard newWidth != widthSteps || newHeight != heightSteps else { return }
        widthSteps = newWidth
        heightSteps = newHeight
        manager.windowSizeChanged()
    }

    override func pressEnded(_ control: Control, at point: SkinPoint, event: NSEvent) {
        resizeStart = nil
    }

    override func contextMenuRequested(at point: SkinPoint, event: NSEvent) {
        NSMenu.popUpContextMenu(presetMenu(), with: event, for: window.skinView)
    }

    static let presetsInMenu = 60

    /// Presets to pick from, and the window's options.
    func presetMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(WindowManager.item("Next Preset", key: " ") { [weak self] in self?.next(blend: true) })
        menu.addItem(WindowManager.item("Previous Preset", key: "\u{8}") { [weak self] in self?.previous() })
        menu.addItem(WindowManager.item("Random Order", checked: random, key: "r") { [weak self] in
            self?.random.toggle()
            self?.manager.saveLayout()
        })
        menu.addItem(WindowManager.item("Lock Preset", checked: locked, key: "l") { [weak self] in
            self?.locked.toggle()
            self?.manager.saveLayout()
        })
        menu.addItem(WindowManager.item("Full Screen", checked: fullScreen != nil, key: "f") { [weak self] in self?.toggleFullScreen() })
        menu.addItem(.separator())
        menu.addItem(WindowManager.item("Choose Preset…", key: "p") { [weak self] in self?.showBrowser() })
        // A short list fits a submenu; a big collection is for the browser.
        if library.presets.count <= Self.presetsInMenu {
            let presets = NSMenu()
            for url in library.presets {
                let title = PresetLibrary.name(url) + (library.isHeavy(url) ? " (slow)" : "")
                presets.addItem(WindowManager.item(title, checked: url == currentPreset) { [weak self] in self?.show(url, blend: true, byHand: true) })
            }
            menu.addItem(WindowManager.submenu("Presets", presets))
        }
        menu.addItem(WindowManager.item("Show Presets Folder") {
            NSWorkspace.shared.activateFileViewerSelecting([PresetLibrary.userFolder])
        })
        return menu
    }

    // MARK: - Full screen

    func toggleFullScreen() {
        if let fullScreen {
            fullScreen.close()
            self.fullScreen = nil
            window.skinView.addSubview(metalView)
            manager.render()
            window.makeKeyAndOrderFront(nil)
            updateDrawing()
        } else {
            guard let screen = window.screen ?? NSScreen.main else { return }
            fullScreen = FullScreenVisualization(view: metalView, screen: screen, controller: self)
            updateDrawing()
        }
    }
}

extension VisualizationWindowController {
    /// Self test: every preset drawn offscreen after `frames` frames of a
    /// beating test signal, side by side (4 per row), as PNG data.
    func presetSheetForTesting(width: Int = 256, height: Int = 192, frames: Int = 120) -> Data? {
        guard let renderer = MilkdropRenderer(targetFormat: .rgba8Unorm) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let presets = library.presets.compactMap(library.load)
        let columns = 4, rows = (presets.count + columns - 1) / columns
        var sheet = Bitmap(width: columns * width, height: rows * height, fill: PixelColor(rgb: 0x202020))
        for (n, preset) in presets.enumerated() {
            guard let target = renderer.device.makeTexture(descriptor: descriptor) else { return nil }
            let session = MilkdropSession()
            session.load(preset, at: 0, blend: false)
            var pixels: [UInt8] = []
            for f in 0..<frames {
                let t = Double(f) / 60
                // A 220 Hz tone that swells on every beat (twice a second).
                let beat = 0.2 + 0.8 * pow(max(0, cos(t * .pi * 2)), 8)
                let samples = (0..<1024).map { Float(sin(Double($0 + f * 735) * 2 * .pi * 220 / 44100) * beat) }
                guard let frame = session.frame(time: t, samples: samples, size: SIMD2(Double(width), Double(height))),
                    let buffer = renderer.makeCommandBuffer()
                else { continue }
                renderer.render(frame, to: target, commandBuffer: buffer)
                buffer.commit()
                buffer.waitUntilCompleted()
                if f == frames - 1 { pixels = renderer.pixels(of: target) }
            }
            let ox = (n % columns) * width, oy = (n / columns) * height
            for y in 0..<height {
                for x in 0..<width where !pixels.isEmpty {
                    let i = (y * width + x) * 4
                    sheet[ox + x, oy + y] = PixelColor(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2])
                }
            }
        }
        return sheet.pngData()
    }
}

/// Draws the visualization on its own thread, in step with the display
/// (CAMetalDisplayLink): whatever the main thread is busy with, frames keep
/// coming, and each one is animated for the moment it will be on screen.
private final class VisualizationRenderLoop: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    // Used only on the render thread.
    private let renderer: MilkdropRenderer
    private let session = MilkdropSession()
    private let samples: SampleBuffer
    private let link: CAMetalDisplayLink
    private let start = CACurrentMediaTime()
    private var locked = false
    private var finishReported = false
    /// Seconds a preset stays before the next one blends in.
    private let presetSeconds = 20.0
    private let onPresetFinished: @MainActor @Sendable () -> Void
    private let onTooHeavy: @MainActor @Sendable () -> Void
    /// What the current preset's frames cost here (the engine and encoding,
    /// seconds), over the last second and a half, once it has settled in.
    private var costs: [Double] = []
    private var framesSinceLoad = 0
    private var slowRun = 0
    private var heavyReported = false
    /// Most of a 60 fps frame: the GPU and everything else need the rest.
    private static let frameBudget = 0.012
    /// A frame this slow is a stall; a few in a row are enough.
    private static let stallLimit = 0.1

    private var runLoop: CFRunLoop?
    private let frames = OSAllocatedUnfairLock(initialState: 0)

    /// `onPresetFinished` runs on the main thread when the preset has had its
    /// time, `onTooHeavy` when it keeps missing the display's pace.
    init?(
        layer: CAMetalLayer, samples: SampleBuffer, onPresetFinished: @escaping @MainActor @Sendable () -> Void,
        onTooHeavy: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let device = layer.device, let renderer = MilkdropRenderer(device: device, targetFormat: layer.pixelFormat) else { return nil }
        self.renderer = renderer
        self.samples = samples
        self.onPresetFinished = onPresetFinished
        self.onTooHeavy = onTooHeavy
        link = CAMetalDisplayLink(metalLayer: layer)
        super.init()
        session.presetDuration = presetSeconds
        // MilkDrop presets are made for 60 frames a second (trails fade per frame).
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.preferredFrameLatency = 2
        link.isPaused = true
        link.delegate = self

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            link.add(to: .current, forMode: .default)
            ready.signal()
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        thread.name = "Visualization"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 8 << 20  // preset code is compiled and run recursively
        thread.start()
        ready.wait()
    }

    private var now: Double { CACurrentMediaTime() - start }

    var framesDrawn: Int { frames.withLock { $0 } }

    func load(_ preset: MilkdropPreset, blend: Bool) {
        perform { loop in
            loop.session.load(preset, at: loop.now, blend: blend)
            loop.finishReported = false
            loop.costs.removeAll()
            loop.framesSinceLoad = 0
            loop.slowRun = 0
            loop.heavyReported = false
        }
    }

    func setPaused(_ paused: Bool) {
        perform { $0.link.isPaused = paused }
    }

    /// A locked preset stays until switched by hand.
    func setLocked(_ locked: Bool) {
        perform { $0.locked = locked }
    }

    /// Runs `work` on the render thread, between frames.
    private func perform(_ work: @escaping @Sendable (VisualizationRenderLoop) -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { work(self) }
        CFRunLoopWakeUp(runLoop)
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let started = CACurrentMediaTime()
        let time = update.targetPresentationTimestamp - start
        let texture = update.drawable.texture
        guard let frame = session.frame(time: time, samples: samples.latest(1024), size: SIMD2(Double(texture.width), Double(texture.height))),
            let buffer = renderer.makeCommandBuffer()
        else { return }
        renderer.render(frame, to: texture, commandBuffer: buffer)
        buffer.present(update.drawable)
        buffer.commit()
        frames.withLock { $0 += 1 }
        measure(CACurrentMediaTime() - started)
        if !locked, !finishReported, session.elapsed(at: time) > presetSeconds, !session.isBlending {
            finishReported = true
            let finished = onPresetFinished
            Task { @MainActor in finished() }
        }
    }
}

extension VisualizationRenderLoop {
    /// Blends (two presets at once) and the first frames don't count.
    fileprivate func measure(_ cost: Double) {
        framesSinceLoad += 1
        guard !heavyReported, !session.isBlending, framesSinceLoad > 5 else { return }
        costs.append(cost)
        if costs.count > 90 { costs.removeFirst() }
        slowRun = cost > Self.stallLimit ? slowRun + 1 : 0
        let average = costs.reduce(0, +) / Double(costs.count)
        guard slowRun >= 5 || (costs.count >= 30 && average > Self.frameBudget) else { return }
        heavyReported = true
        let tooHeavy = onTooHeavy
        Task { @MainActor in tooHeavy() }
    }
}

/// The CAMetalLayer the visualization draws into, sized in pixels; the
/// mouse goes to the skinned window around it.
private final class MetalLayerView: NSView {
    let metalLayer = CAMetalLayer()

    init(device: MTLDevice?) {
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = true
        wantsLayer = true
        layerContentsRedrawPolicy = .never  // only Metal draws here
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }
}

/// The visualization on a whole screen: the Dock and menu bar step aside,
/// the pointer hides until it moves; Esc or a double-click comes back.
@MainActor
private final class FullScreenVisualization {
    private let window: KeyWindow
    private let previousOptions: NSApplication.PresentationOptions

    init(view: NSView, screen: NSScreen, controller: VisualizationWindowController) {
        window = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.onKey = { [weak controller] in controller?.handleVisualizationKey($0) ?? false }
        window.onDoubleClick = { [weak controller] in controller?.toggleFullScreen() }
        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window.contentView = container
        window.setFrame(screen.frame, display: true)
        previousOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func close() {
        NSApp.presentationOptions = previousOptions
        window.contentView?.subviews.forEach { $0.autoresizingMask = [] }
        window.orderOut(nil)
    }
}

/// A borderless window that takes keys and reports double-clicks.
private final class KeyWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    var onDoubleClick: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}
