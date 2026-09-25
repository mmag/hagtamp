import AppKit
import SkinKit

/// A point in skin pixels (window bitmap coordinates, top-left origin).
struct SkinPoint {
    var x: Int
    var y: Int
}

@MainActor
protocol SkinViewDelegate: AnyObject {
    func mouseDown(at point: SkinPoint, event: NSEvent)
    func mouseDragged(to point: SkinPoint, event: NSEvent)
    func mouseUp(at point: SkinPoint, event: NSEvent)
    func rightMouseDown(at point: SkinPoint, event: NSEvent)
    func scrollWheel(at point: SkinPoint, event: NSEvent)
    /// Skin cursor for a point; nil shows the system arrow.
    func cursor(at point: SkinPoint) -> SkinCursorName?
    /// A system cursor where skins have none (column dividers); wins over `cursor(at:)`.
    func systemCursor(at point: SkinPoint) -> NSCursor?
    func keyDown(_ event: NSEvent) -> Bool
    func filesDropped(_ urls: [URL], at point: SkinPoint)
}

/// Shows a window bitmap pixel-exactly: one skin pixel is one point
/// (two in double-size mode), scaled with nearest-neighbour filtering.
final class SkinView: NSView {
    weak var delegate: SkinViewDelegate?
    var cursors: CursorController?

    private var bitmapWidth = 1
    private var isTrackingMouse = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        layer?.contentsGravity = .resize
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Winamp reacts to the first click even in an inactive window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ bitmap: Bitmap) {
        bitmapWidth = max(1, bitmap.width)
        layer?.contents = bitmap.makeCGImage()
    }

    private func skinPoint(_ event: NSEvent) -> SkinPoint {
        let p = convert(event.locationInWindow, from: nil)
        let scale = bounds.width / CGFloat(bitmapWidth)
        return SkinPoint(x: Int((p.x / scale).rounded(.down)), y: Int((p.y / scale).rounded(.down)))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true
        delegate?.mouseDown(at: skinPoint(event), event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        delegate?.mouseDragged(to: skinPoint(event), event: event)
    }

    override func mouseUp(with event: NSEvent) {
        isTrackingMouse = false
        delegate?.mouseUp(at: skinPoint(event), event: event)
        updateCursor(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.rightMouseDown(at: skinPoint(event), event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        delegate?.scrollWheel(at: skinPoint(event), event: event)
    }

    override func keyDown(with event: NSEvent) {
        if delegate?.keyDown(event) != true { super.keyDown(with: event) }
    }

    // MARK: - Cursors

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func mouseEntered(with event: NSEvent) { updateCursor(event) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }

    override func mouseExited(with event: NSEvent) {
        guard !isTrackingMouse else { return }
        cursors?.show(nil)
    }

    private func updateCursor(_ event: NSEvent) {
        guard !isTrackingMouse else { return }
        let point = skinPoint(event)
        if let cursor = delegate?.systemCursor(at: point) {
            cursors?.show(system: cursor)
        } else {
            cursors?.show(delegate?.cursor(at: point))
        }
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        let scale = bounds.width / CGFloat(bitmapWidth)
        delegate?.filesDropped(urls, at: SkinPoint(x: Int(p.x / scale), y: Int(p.y / scale)))
        return true
    }

    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}
