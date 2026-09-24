import SkinKit

public enum WindowID: String, Hashable, Sendable, CaseIterable, Codable {
    case main, equalizer, playlist, albumArt, navidromeLibrary, localLibrary
}

/// A window's frame in global top-left coordinates (y grows downwards), in points.
public struct WindowBox: Hashable, Sendable {
    public var id: WindowID
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(_ id: WindowID, x: Int, y: Int, width: Int, height: Int) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var right: Int { x + width }
    public var bottom: Int { y + height }

    public func offsetBy(dx: Int, dy: Int) -> WindowBox {
        WindowBox(id, x: x + dx, y: y + dy, width: width, height: height)
    }
}

/// Winamp's window docking: snapping while dragging, the main window pulling
/// its docked windows along, and docked windows staying attached when sizes
/// change. Adapted from Webamp's snapUtils/resizeUtils (MIT, see
/// THIRD_PARTY_NOTICES.md).
public enum WindowDocking {
    /// Winamp's default snap distance.
    public static let snapDistance = 10

    /// Two windows are docked when they touch along an edge they share.
    public static func touching(_ a: WindowBox, _ b: WindowBox) -> Bool {
        let overlapX = a.x < b.right && b.x < a.right
        let overlapY = a.y < b.bottom && b.y < a.bottom
        return (overlapY && (a.right == b.x || b.right == a.x)) || (overlapX && (a.bottom == b.y || b.bottom == a.y))
    }

    /// Windows that move when `id` is dragged: the main window takes every
    /// window docked to it (directly or through others); the others move alone.
    public static func movingGroup(dragging id: WindowID, windows: [WindowBox]) -> Set<WindowID> {
        guard id == .main, let start = windows.first(where: { $0.id == id }) else { return [id] }
        var group: Set<WindowID> = [id]
        var queue = [start]
        while let current = queue.popLast() {
            for other in windows where !group.contains(other.id) && touching(current, other) {
                group.insert(other.id)
                queue.append(other)
            }
        }
        return group
    }

    /// The offset to apply to the dragged windows: the pointer's offset,
    /// corrected per axis by the nearest snap to a stationary window or to
    /// the edges of a screen's usable area.
    public static func snappedOffset(
        moving: [WindowBox], stationary: [WindowBox], screens: [WindowBox], dx: Int, dy: Int
    ) -> (dx: Int, dy: Int) {
        let proposed = moving.map { $0.offsetBy(dx: dx, dy: dy) }
        var bestX: Int?, bestY: Int?
        func consider(_ correction: Int, _ best: inout Int?) {
            guard abs(correction) < snapDistance else { return }
            if best == nil || abs(correction) < abs(best!) { best = correction }
        }

        for m in proposed {
            for s in stationary {
                if m.y <= s.bottom + snapDistance && s.y <= m.bottom + snapDistance {
                    consider(s.right - m.x, &bestX)
                    consider(s.x - m.right, &bestX)
                    consider(s.x - m.x, &bestX)
                    consider(s.right - m.right, &bestX)
                }
                if m.x <= s.right + snapDistance && s.x <= m.right + snapDistance {
                    consider(s.bottom - m.y, &bestY)
                    consider(s.y - m.bottom, &bestY)
                    consider(s.y - m.y, &bestY)
                    consider(s.bottom - m.bottom, &bestY)
                }
            }
        }

        if let bounds = boundingBox(proposed) {
            // Snap the group to the inside edges of the screen it is mostly on.
            let centerX = bounds.x + bounds.width / 2, centerY = bounds.y + bounds.height / 2
            let screen =
                screens.first { centerX >= $0.x && centerX < $0.right && centerY >= $0.y && centerY < $0.bottom }
                ?? screens.first
            if let screen {
                consider(screen.x - bounds.x, &bestX)
                consider(screen.right - bounds.right, &bestX)
                consider(screen.y - bounds.y, &bestY)
                consider(screen.bottom - bounds.bottom, &bestY)
            }
        }
        return (dx + (bestX ?? 0), dy + (bestY ?? 0))
    }

    /// New frames after some windows change size (shade, double size,
    /// playlist resize): windows docked below or to the right of a window that
    /// grew or shrank move with its edge. The windows' top-left corners stay
    /// put otherwise.
    public static func reflow(_ windows: [WindowBox], newSizes: [WindowID: (width: Int, height: Int)]) -> [WindowBox] {
        // Which window each one hangs under / sits right of, before the change.
        var under: [WindowID: WindowID] = [:]
        var rightOf: [WindowID: WindowID] = [:]
        for w in windows {
            under[w.id] = windows.first { o in o.id != w.id && o.bottom == w.y && o.x < w.right && w.x < o.right }?.id
            rightOf[w.id] = windows.first { o in o.id != w.id && o.right == w.x && o.y < w.bottom && w.y < o.bottom }?.id
        }
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        func sizeDelta(_ id: WindowID) -> (dw: Int, dh: Int) {
            guard let old = byID[id], let new = newSizes[id] else { return (0, 0) }
            return (new.width - old.width, new.height - old.height)
        }

        var moved: [WindowID: (dx: Int, dy: Int)] = [:]
        func offset(_ id: WindowID, visiting: Set<WindowID> = []) -> (dx: Int, dy: Int) {
            if let known = moved[id] { return known }
            guard !visiting.contains(id) else { return (0, 0) }
            let visiting = visiting.union([id])
            var dx = 0, dy = 0
            if let parent = under[id] {
                let p = offset(parent, visiting: visiting)
                dy = p.dy + sizeDelta(parent).dh
                dx = p.dx
            }
            if let parent = rightOf[id] {
                let p = offset(parent, visiting: visiting)
                dx = p.dx + sizeDelta(parent).dw
                if under[id] == nil { dy = p.dy }
            }
            moved[id] = (dx, dy)
            return (dx, dy)
        }

        return windows.map { w in
            let o = offset(w.id)
            let size = newSizes[w.id] ?? (w.width, w.height)
            return WindowBox(w.id, x: w.x + o.dx, y: w.y + o.dy, width: size.width, height: size.height)
        }
    }

    static func boundingBox(_ boxes: [WindowBox]) -> WindowBox? {
        guard let first = boxes.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.right, maxY = first.bottom
        for b in boxes.dropFirst() {
            minX = min(minX, b.x)
            minY = min(minY, b.y)
            maxX = max(maxX, b.right)
            maxY = max(maxY, b.bottom)
        }
        return WindowBox(first.id, x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether a window can be grabbed on some screen: at least 30 x 8 points
    /// of its title bar (the top 14) lie on it.
    public static func isReachable(_ box: WindowBox, screens: [WindowBox]) -> Bool {
        screens.contains { screen in
            let width = min(box.right, screen.right) - max(box.x, screen.x)
            let height = min(box.y + min(14, box.height), screen.bottom) - max(box.y, screen.y)
            return width >= 30 && height >= 8
        }
    }

    /// Saved windows on today's screens. When the main window can't be
    /// reached (its screen is gone), every window moves with it so that it
    /// lands at `home`, keeping docked windows docked. Windows still out of
    /// reach after that are left out of `placed` for the caller to put back.
    public static func restore(
        _ windows: [WindowBox], screens: [WindowBox], home: (x: Int, y: Int)
    ) -> (placed: [WindowBox], unreachable: [WindowID]) {
        var windows = windows
        if let main = windows.first(where: { $0.id == .main }), !isReachable(main, screens: screens) {
            let dx = home.x - main.x, dy = home.y - main.y
            windows = windows.map { $0.offsetBy(dx: dx, dy: dy) }
        }
        let placed = windows.filter { isReachable($0, screens: screens) }
        return (placed, windows.filter { !isReachable($0, screens: screens) }.map(\.id))
    }
}
