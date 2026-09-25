import AppKit
import SkinKit

/// Turns the skin's cursors into NSCursors and shows them, animating .ani
/// cursors frame by frame.
@MainActor
final class CursorController {
    private var cursors: [SkinCursorName: SkinCursor] = [:]
    private var cache: [SkinCursorName: [NSCursor]] = [:]
    private var current: SkinCursorName?
    private var system: NSCursor?
    private var frameIndex = 0
    private var timer: Timer?

    func load(_ skin: Skin) {
        cursors = skin.cursors
        cache = [:]
        let shown = current
        current = nil
        show(shown)
    }

    /// Shows a skin cursor, or the arrow for nil / cursors the skin lacks.
    func show(_ name: SkinCursorName?) {
        guard name != current || system != nil else { return }
        current = name
        system = nil
        timer?.invalidate()
        timer = nil
        frameIndex = 0
        guard let name, let cursor = cursors[name], let frames = nsCursors(name, cursor) else {
            NSCursor.arrow.set()
            return
        }
        frames[cursor.sequence[0]].set()
        if cursor.isAnimated { scheduleNextFrame(cursor) }
    }

    /// A system cursor, until a skin cursor is shown again.
    func show(system cursor: NSCursor) {
        guard cursor != system else { return }
        timer?.invalidate()
        timer = nil
        current = nil
        system = cursor
        cursor.set()
    }

    private func scheduleNextFrame(_ cursor: SkinCursor) {
        let delay = max(1.0 / 60, cursor.durations[frameIndex])
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                // show() invalidates this timer whenever the cursor changes.
                guard let self, let name = self.current, let frames = self.cache[name] else { return }
                self.frameIndex = (self.frameIndex + 1) % cursor.sequence.count
                frames[cursor.sequence[self.frameIndex]].set()
                self.scheduleNextFrame(cursor)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func nsCursors(_ name: SkinCursorName, _ cursor: SkinCursor) -> [NSCursor]? {
        if let cached = cache[name] { return cached }
        let made = cursor.frames.map { frame -> NSCursor in
            // Cursor pixels are Windows pixels: one per point, drawn crisp on Retina.
            let size = NSSize(width: frame.image.width, height: frame.image.height)
            let image = NSImage(size: size)
            image.addRepresentation(NSBitmapImageRep(cgImage: frame.image.makeCGImage()))
            let retina = NSBitmapImageRep(cgImage: frame.image.scaled(by: 2).makeCGImage())
            retina.size = size
            image.addRepresentation(retina)
            return NSCursor(image: image, hotSpot: NSPoint(x: frame.hotspotX, y: frame.hotspotY))
        }
        cache[name] = made
        return made
    }
}
