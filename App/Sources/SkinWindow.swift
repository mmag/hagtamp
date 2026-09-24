import AppKit
import SkinKit

/// A borderless window whose whole appearance comes from the skin.
final class SkinWindow: NSWindow {
    let skinView: SkinView
    var onFocusChange: (() -> Void)?
    /// Given a place on screen yet (until then it's 1x1 in a corner).
    var isPlaced = false

    init() {
        skinView = SkinView(frame: .zero)
        // Not .zero: a window that starts empty never shows Metal layers
        // added to it later (they draw, but stay off screen).
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
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
