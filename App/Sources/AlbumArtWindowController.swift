import AppKit
import AudioCore
import ClassicUI
import SkinKit

/// Optional window with the current track's cover, in a generic skinned
/// frame like Winamp 5's album art window. The cover is shown at full
/// resolution over the pixel-art frame.
@MainActor
final class AlbumArtWindowController: SkinWindowController {
    private var widthSteps = 0
    /// 290 px tall: a 256x256 cover area at the default width.
    private var heightSteps = 6
    private let imageView = PassthroughImageView()
    private var shownTrack: URL?
    private var resizeStart: (mouse: NSPoint, width: Int, height: Int)?
    /// Covers by track, so moving within an album doesn't hit the disk again.
    private var cache: [URL: NSImage] = [:]

    init(manager: WindowManager) {
        super.init(id: .albumArt, manager: manager)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        window.skinView.addSubview(imageView)
    }

    private var width: Int { GenWindowRenderer.baseWidth + widthSteps * 25 }
    private var height: Int { GenWindowRenderer.baseHeight + heightSteps * 29 }

    override func regions() -> [ControlRegion] { GenWindowLayout.regions(width: width, height: height) }
    override func pixelSize() -> (width: Int, height: Int) { (width, height) }
    override func titleBarDoubleClicked() {}  // generic windows have no shade mode

    override func savedState() -> [String: Int] { ["width": widthSteps, "height": heightSteps] }

    override func restore(_ state: [String: Int]) {
        widthSteps = max(0, state["width"] ?? widthSteps)
        heightSteps = max(0, state["height"] ?? heightSteps)
    }

    override func renderBitmap() -> Bitmap {
        var state = GenWindowState(title: "Album Art")
        state.focused = isFocused
        state.pressed = pressed
        state.widthSteps = widthSteps
        state.heightSteps = heightSteps
        updateCover()
        let content = GenWindowRenderer.contentRect(width: width, height: height)
        let scale = CGFloat(manager.scale)
        imageView.frame = NSRect(
            x: CGFloat(content.x) * scale, y: CGFloat(content.y) * scale,
            width: CGFloat(content.width) * scale, height: CGFloat(content.height) * scale)
        return GenWindowRenderer.render(manager.skin, state)
    }

    /// Loads the cover when the displayed track changes (off the main thread).
    private func updateCover() {
        let track = manager.model.displayedTrack?.url
        guard track != shownTrack else { return }
        shownTrack = track
        guard let track else {
            imageView.image = nil
            return
        }
        if let cached = cache[track] {
            imageView.image = cached
            return
        }
        imageView.image = nil
        Task { [weak self] in
            let image = await self?.manager.cover(for: track)
            self?.show(image, for: track)
        }
    }

    private func show(_ image: NSImage?, for track: URL) {
        if let image { cache[track] = image }
        if shownTrack == track { imageView.image = image }
    }

    var hasCover: Bool { imageView.image != nil }

    // MARK: - Pointer

    override func buttonClicked(_ control: Control) {
        if control == .close { manager.setVisible(.albumArt, false) }
    }

    override func pressBegan(_ control: Control, at point: SkinPoint, event: NSEvent) -> Bool {
        guard control == .resize else { return false }
        resizeStart = (NSEvent.mouseLocation, widthSteps, heightSteps)
        return true
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
        manager.showMainMenu(for: event, in: window.skinView)
    }
}

/// An image view that lets clicks through to the skinned window below.
final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
