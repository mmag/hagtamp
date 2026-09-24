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
        initialFirstResponder = skinView
        makeFirstResponder(skinView)  // transport keys go to the skin view
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
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
}
