import CoreGraphics
import SkinKit

/// What the lyrics window shows.
public struct LyricsWindowState: Sendable {
    public var frame: GenWindowState
    public var lines: [String] = []
    /// The line being sung (synced lyrics).
    public var current: Int?
    /// Shown instead of lines: "Loading lyrics…", "No lyrics".
    public var message: String?
    /// Scroll position, in wrapped rows.
    public var firstRow = 0

    public init(frame: GenWindowState) {
        self.frame = frame
    }
}

/// Lines wrapped to the window, one row each; shared by rendering and clicks.
public struct LyricsLayout: Sendable {
    public static let rowHeight = 13
    public let area: PixelRect
    /// Wrapped rows and the lyrics line each belongs to.
    public let rows: [(line: Int, text: String)]

    public init(lines: [String], width: Int, height: Int, fontName: String) {
        let content = GenWindowRenderer.contentRect(width: width, height: height)
        area = PixelRect(x: content.x + 6, y: content.y + 4, width: max(1, content.width - 12), height: max(1, content.height - 8))
        var rows: [(Int, String)] = []
        for (index, line) in lines.enumerated() {
            for row in Self.wrap(line, width: area.width, fontName: fontName) { rows.append((index, row)) }
        }
        self.rows = rows
    }

    public var visibleRows: Int { max(1, area.height / Self.rowHeight) }
    public var maxFirstRow: Int { max(0, rows.count - visibleRows) }

    /// The scroll position that puts `line` in the middle.
    public func firstRow(centering line: Int) -> Int {
        guard let first = rows.firstIndex(where: { $0.line == line }) else { return 0 }
        let count = rows.filter { $0.line == line }.count
        return min(maxFirstRow, max(0, first + count / 2 - visibleRows / 2))
    }

    public func line(atY y: Int, firstRow: Int) -> Int? {
        guard y >= area.y, y < area.y + visibleRows * Self.rowHeight else { return nil }
        let row = firstRow + (y - area.y) / Self.rowHeight
        return rows.indices.contains(row) ? rows[row].line : nil
    }

    /// Word wrap; a word longer than the width is cut where it must.
    static func wrap(_ text: String, width: Int, fontName: String) -> [String] {
        guard !text.isEmpty else { return [""] }
        func fits(_ s: String) -> Bool { SystemText.width(s, fontName: fontName) <= width }
        var rows: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if fits(candidate) {
                current = candidate
                continue
            }
            if !current.isEmpty { rows.append(current) }
            current = word
            while !fits(current), current.count > 1 {
                var head = current
                while !fits(head), head.count > 1 { head.removeLast() }
                rows.append(head)
                current.removeFirst(head.count)
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

/// The lyrics window: a generic skinned frame with the words centred in the
/// playlist's colours and font, the current line in the "current track" colour.
public enum LyricsRenderer {
    public static func render(_ skin: Skin, _ state: LyricsWindowState) -> Bitmap {
        let style = skin.playlistStyle
        var frame = state.frame
        frame.contentColor = style.normalBackground
        var canvas = GenWindowRenderer.render(skin, frame)
        let layout = LyricsLayout(lines: state.lines, width: frame.pixelWidth, height: frame.pixelHeight, fontName: style.font)
        if let message = state.message ?? (state.lines.isEmpty ? "" : nil) {
            SystemText.draw(&canvas, message, in: layout.area, color: style.normal, fontName: style.font, alignment: .center)
            return canvas
        }
        let first = min(max(0, state.firstRow), layout.maxFirstRow)
        for (i, row) in layout.rows.dropFirst(first).prefix(layout.visibleRows).enumerated() {
            let rect = PixelRect(x: layout.area.x, y: layout.area.y + i * LyricsLayout.rowHeight, width: layout.area.width, height: LyricsLayout.rowHeight)
            SystemText.draw(&canvas, row.text, in: rect, color: row.line == state.current ? style.current : style.normal, fontName: style.font, alignment: .center)
        }
        return canvas
    }
}
