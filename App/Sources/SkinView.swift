import AppKit
import SkinKit

/// Shows a window bitmap pixel-exactly: one skin pixel is one point
/// (two in double-size mode), scaled with nearest-neighbour filtering.
final class SkinView: NSView {
    var onFileDrop: ((URL) -> Void)?

    private(set) var bitmapSize = CGSize(width: 1, height: 1)

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

    func show(_ bitmap: Bitmap) {
        bitmapSize = CGSize(width: bitmap.width, height: bitmap.height)
        layer?.contents = bitmap.makeCGImage()
    }

    // Clicks anywhere drag the window until stage 2 brings real hit-testing.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURL(sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedURL(sender) else { return false }
        onFileDrop?(url)
        return true
    }

    private func droppedURL(_ sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first { ["wsz", "zip"].contains($0.pathExtension.lowercased()) }
    }
}
