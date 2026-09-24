import AppKit
import AudioCore
import ClassicUI
import Metal
import os
import Milkdrop
import MilkdropMetal
import QuartzCore
import SkinKit

/// Presets (.milk): the ones that come with the app, then the user's in
/// Application Support/Hagtamp/Presets, by name.
@MainActor
final class PresetLibrary {
    static var userFolder: URL {
        let folder = Storage.supportDirectory.appendingPathComponent("Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private(set) var presets: [URL] = []

    init() {
        reload()
    }

    func reload() {
        let folders = [Bundle.main.url(forResource: "Presets", withExtension: nil), Self.userFolder].compactMap { $0 }
        let files = folders.flatMap { folder in
            FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        }
        presets = files.filter { $0.pathExtension.lowercased() == "milk" }
            .sorted { Self.name($0).localizedStandardCompare(Self.name($1)) == .orderedAscending }
    }

    static func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    func load(_ url: URL) -> MilkdropPreset? {
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        return MilkdropPreset.parse(text, name: Self.name(url))
    }
}

/// The visualization window: MilkDrop-style presets drawn with Metal in a
/// generic skinned frame, or full screen. Keys as in MilkDrop: Space or →
/// next preset (blended), ← or Backspace previous, H hard cut, R random
/// order, L keep this preset, F/Return/double-click full screen, Esc back.
@MainActor
final class VisualizationWindowController: SkinWindowController {
    private var widthSteps = 5
    private var heightSteps = 8
    private var resizeStart: (mouse: NSPoint, width: Int, height: Int)?
    private let metalView: MetalLayerView
    private var renderLoop: VisualizationRenderLoop?
    let library = PresetLibrary()
    private(set) var presetIndex = -1
    private var history: [Int] = []
    var random = true
    var locked = false {
        didSet { renderLoop?.setLocked(locked) }
    }
    private var fullScreen: FullScreenVisualization?

    init(manager: WindowManager) {
        let view = MetalLayerView(device: MTLCreateSystemDefaultDevice())
        metalView = view
        super.init(id: .visualization, manager: manager)
        renderLoop = VisualizationRenderLoop(layer: view.metalLayer, samples: manager.model.engine.samples) { [weak self] in
            self?.next(blend: true)
        }
        window.skinView.addSubview(view)
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

    /// Draws only while someone can see it.
    override func visibilityChanged(_ visible: Bool) {
        if visible, presetIndex < 0 { next(blend: false) }
        renderLoop?.setPaused(!visible && fullScreen == nil)
    }

    // MARK: - Presets

    func next(blend: Bool) {
        let count = library.presets.count
        guard count > 0 else { return }
        var index = random ? Int.random(in: 0..<count) : (presetIndex + 1) % count
        if random, count > 1, index == presetIndex { index = (index + 1) % count }
        show(index, blend: blend)
    }

    func previous() {
        guard history.count > 1 else { return }
        history.removeLast()
        show(history.removeLast(), blend: true)
    }

    func show(_ index: Int, blend: Bool) {
        guard library.presets.indices.contains(index), let preset = library.load(library.presets[index]) else { return }
        presetIndex = index
        history.append(index)
        if history.count > 50 { history.removeFirst() }
        renderLoop?.load(preset, blend: blend)
        announce(preset.name)
    }

    /// The preset's name shows in the main window's marquee for a moment.
    private func announce(_ text: String) {
        manager.marqueeMessage = text.uppercased()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if self?.manager.marqueeMessage == text.uppercased() { self?.manager.marqueeMessage = nil }
        }
    }

    var currentPresetName: String? {
        library.presets.indices.contains(presetIndex) ? PresetLibrary.name(library.presets[presetIndex]) : nil
    }

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
        let presets = NSMenu()
        for (index, url) in library.presets.enumerated() {
            presets.addItem(WindowManager.item(PresetLibrary.name(url), checked: index == presetIndex) { [weak self] in self?.show(index, blend: true) })
        }
        menu.addItem(WindowManager.submenu("Presets", presets))
        menu.addItem(WindowManager.item("Show Presets Folder") {
            NSWorkspace.shared.activateFileViewerSelecting([PresetLibrary.userFolder])
        })
        menu.addItem(WindowManager.item("Reload Presets") { [weak self] in self?.library.reload() })
        return menu
    }

    // MARK: - Full screen

    func toggleFullScreen() {
        if let fullScreen {
            fullScreen.close()
            self.fullScreen = nil
            window.skinView.addSubview(metalView)
            manager.render()
            renderLoop?.setPaused(!window.isVisible)
            window.makeKeyAndOrderFront(nil)
        } else {
            guard let screen = window.screen ?? NSScreen.main else { return }
            fullScreen = FullScreenVisualization(view: metalView, screen: screen, controller: self)
            renderLoop?.setPaused(false)
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

    private var runLoop: CFRunLoop?
    private let frames = OSAllocatedUnfairLock(initialState: 0)

    /// `onPresetFinished` runs on the main thread when the preset has had its time.
    init?(layer: CAMetalLayer, samples: SampleBuffer, onPresetFinished: @escaping @MainActor @Sendable () -> Void) {
        guard let device = layer.device, let renderer = MilkdropRenderer(device: device, targetFormat: layer.pixelFormat) else { return nil }
        self.renderer = renderer
        self.samples = samples
        self.onPresetFinished = onPresetFinished
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
        thread.start()
        ready.wait()
    }

    private var now: Double { CACurrentMediaTime() - start }

    var framesDrawn: Int { frames.withLock { $0 } }

    func load(_ preset: MilkdropPreset, blend: Bool) {
        perform { loop in
            loop.session.load(preset, at: loop.now, blend: blend)
            loop.finishReported = false
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
        let time = update.targetPresentationTimestamp - start
        let texture = update.drawable.texture
        guard let frame = session.frame(time: time, samples: samples.latest(1024), size: SIMD2(Double(texture.width), Double(texture.height))),
            let buffer = renderer.makeCommandBuffer()
        else { return }
        renderer.render(frame, to: texture, commandBuffer: buffer)
        buffer.present(update.drawable)
        buffer.commit()
        frames.withLock { $0 += 1 }
        if !locked, !finishReported, session.elapsed(at: time) > presetSeconds, !session.isBlending {
            finishReported = true
            let finished = onPresetFinished
            Task { @MainActor in finished() }
        }
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
