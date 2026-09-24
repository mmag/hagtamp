import AppKit
import SkinKit

/// A borderless window whose whole appearance comes from the skin.
final class SkinWindow: NSWindow {
    let skinView: SkinView
    var onFocusChange: (() -> Void)?

    init() {
        skinView = SkinView(frame: .zero)
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        contentView = skinView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.managed, .participatesInCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        onFocusChange?()
    }

    override func resignKey() {
        super.resignKey()
        onFocusChange?()
    }

    /// Shows `bitmap`, resizing the window around its top-left corner.
    func show(_ bitmap: Bitmap, scale: Int) {
        skinView.show(bitmap)
        let size = CGSize(width: bitmap.width * scale, height: bitmap.height * scale)
        guard frame.size != size else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }
}
