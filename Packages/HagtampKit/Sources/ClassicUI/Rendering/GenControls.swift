import CoreGraphics
import CoreText
import Foundation
import SkinKit

/// Text in the skin's system font (pledit.txt), drawn crisp at 1x like
/// Winamp's GDI text.
public enum SystemText {
    public enum Alignment: Sendable { case left, right, center }

    public static func draw(
        _ canvas: inout Bitmap, _ text: String, in rect: PixelRect, color: PixelColor, fontName: String,
        size: CGFloat = 9, alignment: Alignment = .left
    ) {
        guard !text.isEmpty, !rect.isEmpty else { return }
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let height = canvas.height
        var x = CGFloat(rect.x)
        switch alignment {
        case .left: break
        case .right: x = CGFloat(rect.maxX) - ceil(width)
        case .center: x = CGFloat(rect.x) + ((CGFloat(rect.width) - width) / 2).rounded()
        }
        // Baseline centred in the rect, in CoreGraphics' bottom-up coordinates.
        let top = CGFloat(rect.y) + ((CGFloat(rect.height) - (ascent + descent)) / 2).rounded()
        let baseline = CGFloat(height) - (top + ascent.rounded())
        canvas.withCGContext { ctx in
            ctx.setShouldAntialias(false)
            ctx.setShouldSmoothFonts(false)
            ctx.clip(to: CGRect(x: rect.x, y: height - rect.maxY, width: rect.width, height: rect.height))
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, ctx)
        }
    }

    public static func width(_ text: String, fontName: String, size: CGFloat = 9) -> Int {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }
}

public struct ListColumn: Sendable, Equatable {
    public var title: String
    /// Fixed width; nil columns share the rest.
    public var width: Int?
    public var alignRight: Bool

    public init(_ title: String, width: Int? = nil, alignRight: Bool = false) {
        self.title = title
        self.width = width
        self.alignRight = alignRight
    }
}

/// Contents of a list view (Winamp 5 media library style).
public struct ListViewModel: Sendable, Equatable {
    public var columns: [ListColumn]
    public var rows: [[String]]
    public var selection: Set<Int> = []
    public var firstVisibleRow = 0
    /// The list has keyboard focus (selection drawn "highlighted").
    public var focused = false
    public var showsHeader = true
    public var showsScrollbar = true
    /// Shown when there are no rows ("Loading…", errors).
    public var placeholder: String?
    public var textSize = TextSize.normal

    public init(columns: [ListColumn], rows: [[String]] = []) {
        self.columns = columns
        self.rows = rows
    }
}

/// Generic-window controls drawn from GENEX.BMP.
public enum GenControls {
    public static let rowHeight = 13
    public static let headerHeight = 14
    public static let scrollbarWidth = 14
    public static let buttonHeight = 15

    // MARK: - List

    public struct ListGeometry: Sendable {
        public let frame: PixelRect
        public let header: PixelRect?
        public let rows: PixelRect
        public let scrollbar: PixelRect
        public let rowHeight: Int

        public var visibleRows: Int { max(0, rows.height / rowHeight) }

        public func row(atY y: Int, firstVisible: Int) -> Int? {
            guard y >= rows.y, y < rows.maxY else { return nil }
            return firstVisible + (y - rows.y) / rowHeight
        }

        public var scrollUp: PixelRect { PixelRect(x: scrollbar.x, y: scrollbar.y, width: scrollbarWidth, height: 14) }
        public var scrollDown: PixelRect { PixelRect(x: scrollbar.x, y: scrollbar.maxY - 14, width: scrollbarWidth, height: 14) }
        public var track: PixelRect { PixelRect(x: scrollbar.x, y: scrollbar.y + 14, width: scrollbarWidth, height: max(0, scrollbar.height - 28)) }

        /// Thumb for a scroll position 0...1, nil when everything fits.
        public func thumb(rowCount: Int, firstVisible: Int) -> PixelRect? {
            let hidden = rowCount - visibleRows
            guard hidden > 0, track.height >= 28 else { return nil }
            let position = Double(min(firstVisible, hidden)) / Double(hidden)
            return PixelRect(x: track.x, y: track.y + Int(Double(track.height - 28) * position), width: scrollbarWidth, height: 28)
        }

        /// First visible row for a thumb dragged to `y` (its top).
        public func firstVisible(forThumbAt y: Int, rowCount: Int) -> Int {
            let hidden = max(0, rowCount - visibleRows)
            guard track.height > 28, hidden > 0 else { return 0 }
            let position = Double(min(max(0, y - track.y), track.height - 28)) / Double(track.height - 28)
            return Int((position * Double(hidden)).rounded())
        }

        /// Column x ranges within the row area; fixed widths grow with the text.
        public func columnRanges(_ columns: [ListColumn], textSize: TextSize = .normal) -> [Range<Int>] {
            let columns = columns.map { column in
                var column = column
                column.width = column.width.map(textSize.scaled)
                return column
            }
            let fixed = columns.compactMap(\.width).reduce(0, +)
            let flexible = columns.filter { $0.width == nil }.count
            let share = flexible > 0 ? max(0, rows.width - fixed) / flexible : 0
            var x = rows.x
            return columns.map { column in
                let width = column.width ?? share
                defer { x += width }
                return x..<x + width
            }
        }
    }

    public static func listGeometry(
        _ frame: PixelRect, showsHeader: Bool, showsScrollbar: Bool = true, textSize: TextSize = .normal
    ) -> ListGeometry {
        let bar = showsScrollbar ? scrollbarWidth : 0
        let headerHeight = textSize.headerHeight
        let header = showsHeader ? PixelRect(x: frame.x, y: frame.y, width: frame.width - bar, height: headerHeight) : nil
        let top = frame.y + (showsHeader ? headerHeight : 0)
        let rows = PixelRect(x: frame.x, y: top, width: frame.width - bar, height: frame.maxY - top)
        let scrollbar = PixelRect(x: frame.maxX - bar, y: frame.y, width: bar, height: showsScrollbar ? frame.height : 0)
        return ListGeometry(frame: frame, header: header, rows: rows, scrollbar: scrollbar, rowHeight: textSize.rowHeight)
    }

    public static func drawList(_ canvas: inout Bitmap, _ skin: Skin, _ colors: GenExColors, _ frame: PixelRect, _ model: ListViewModel) {
        let geometry = listGeometry(frame, showsHeader: model.showsHeader, showsScrollbar: model.showsScrollbar, textSize: model.textSize)
        let font = skin.playlistStyle.font
        let size = model.textSize.fontSize, rowHeight = geometry.rowHeight
        canvas.fill(geometry.rows, with: colors.itemBackground)
        let ranges = geometry.columnRanges(model.columns, textSize: model.textSize)

        if let header = geometry.header {
            canvas.fill(header, with: colors.listHeaderBackground)
            for (column, range) in zip(model.columns, ranges) {
                let cell = PixelRect(x: range.lowerBound, y: header.y, width: range.count, height: header.height)
                // Raised header cells: light top/left edge, dark bottom/right edge.
                canvas.fill(PixelRect(x: cell.x, y: cell.y, width: cell.width, height: 1), with: colors.listHeaderFrameTopLeft)
                canvas.fill(PixelRect(x: cell.x, y: cell.y, width: 1, height: cell.height), with: colors.listHeaderFrameTopLeft)
                canvas.fill(PixelRect(x: cell.x, y: cell.maxY - 1, width: cell.width, height: 1), with: colors.listHeaderFrameBottomRight)
                canvas.fill(PixelRect(x: cell.maxX - 1, y: cell.y, width: 1, height: cell.height), with: colors.listHeaderFrameBottomRight)
                let text = PixelRect(x: cell.x + 3, y: cell.y, width: cell.width - 6, height: cell.height)
                SystemText.draw(&canvas, column.title, in: text, color: colors.listHeaderText, fontName: font, size: size, alignment: column.alignRight ? .right : .left)
            }
        }

        let visible = model.rows.indices.dropFirst(model.firstVisibleRow).prefix(geometry.visibleRows)
        for (line, index) in visible.enumerated() {
            let rowRect = PixelRect(x: geometry.rows.x, y: geometry.rows.y + line * rowHeight, width: geometry.rows.width, height: rowHeight)
            var color = colors.itemForeground
            if model.selection.contains(index) {
                canvas.fill(rowRect, with: model.focused ? colors.listTextHighlightedBackground : colors.listTextSelectedBackground)
                color = model.focused ? colors.listTextHighlighted : colors.listTextSelected
            }
            for (i, range) in ranges.enumerated() where i < model.rows[index].count {
                let cell = PixelRect(x: range.lowerBound + 3, y: rowRect.y, width: range.count - 6, height: rowHeight)
                SystemText.draw(&canvas, model.rows[index][i], in: cell, color: color, fontName: font, size: size, alignment: model.columns[i].alignRight ? .right : .left)
            }
        }
        if model.rows.isEmpty, let placeholder = model.placeholder {
            let rect = PixelRect(x: geometry.rows.x + 4, y: geometry.rows.y + 2, width: geometry.rows.width - 8, height: rowHeight)
            SystemText.draw(&canvas, placeholder, in: rect, color: colors.itemForeground, fontName: font, size: size)
        }
        if model.showsScrollbar {
            drawScrollbar(&canvas, skin, colors, geometry, rowCount: model.rows.count, firstVisible: model.firstVisibleRow)
        }
    }

    public enum ScrollPart: Sendable { case up, down, thumb }

    static func drawScrollbar(
        _ canvas: inout Bitmap, _ skin: Skin, _ colors: GenExColors, _ geometry: ListGeometry, rowCount: Int, firstVisible: Int,
        pressed: ScrollPart? = nil
    ) {
        canvas.fill(geometry.scrollbar, with: colors.scrollbarDeadArea)
        canvas.draw(skin, pressed == .up ? Sprite.GenEx.scrollUpPressed : Sprite.GenEx.scrollUp, x: geometry.scrollUp.x, y: geometry.scrollUp.y)
        canvas.draw(skin, pressed == .down ? Sprite.GenEx.scrollDownPressed : Sprite.GenEx.scrollDown, x: geometry.scrollDown.x, y: geometry.scrollDown.y)
        if let thumb = geometry.thumb(rowCount: rowCount, firstVisible: firstVisible) {
            canvas.draw(skin, pressed == .thumb ? Sprite.GenEx.verticalThumbPressed : Sprite.GenEx.verticalThumb, x: thumb.x, y: thumb.y)
        }
    }

    // MARK: - Button and text field

    /// A GENEX button stretched to `rect` (caps kept, middle tiled).
    public static func drawButton(_ canvas: inout Bitmap, _ skin: Skin, _ colors: GenExColors, _ rect: PixelRect, title: String, pressed: Bool) {
        let sprite = pressed ? Sprite.GenEx.buttonPressed : Sprite.GenEx.button
        let cap = Sprite.GenEx.buttonCap
        let r = sprite.rect
        let clip = PixelRect(x: rect.x, y: rect.y, width: rect.width, height: min(rect.height, r.height))
        canvas.tile(skin, Sprite(sprite.sheet, r.x + cap, r.y, r.width - 2 * cap, r.height), over: PixelRect(x: rect.x + cap, y: rect.y, width: rect.width - 2 * cap, height: clip.height))
        canvas.draw(skin, Sprite(sprite.sheet, r.x, r.y, cap, r.height), x: rect.x, y: rect.y, clip: clip)
        canvas.draw(skin, Sprite(sprite.sheet, r.maxX - cap, r.y, cap, r.height), x: rect.maxX - cap, y: rect.y, clip: clip)
        let text = PixelRect(x: rect.x + 2 + (pressed ? 1 : 0), y: rect.y + (pressed ? 1 : 0), width: rect.width - 4, height: clip.height)
        SystemText.draw(&canvas, title, in: text, color: colors.buttonText, fontName: skin.playlistStyle.font, alignment: .center)
    }

    /// A sunken edit field with an optional caret after the text.
    public static func drawTextField(
        _ canvas: inout Bitmap, _ skin: Skin, _ colors: GenExColors, _ rect: PixelRect, text: String, placeholder: String, focused: Bool, caretVisible: Bool
    ) {
        canvas.fill(rect, with: colors.divider)
        let inner = PixelRect(x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: rect.height - 2)
        canvas.fill(inner, with: colors.itemBackground)
        let font = skin.playlistStyle.font
        let textRect = PixelRect(x: inner.x + 3, y: inner.y, width: inner.width - 6, height: inner.height)
        if text.isEmpty && !focused {
            SystemText.draw(&canvas, placeholder, in: textRect, color: colors.divider, fontName: font)
        } else {
            SystemText.draw(&canvas, text, in: textRect, color: colors.itemForeground, fontName: font)
        }
        if focused && caretVisible {
            let x = min(textRect.maxX - 1, textRect.x + SystemText.width(text, fontName: font) + 1)
            canvas.fill(PixelRect(x: x, y: inner.y + 2, width: 1, height: inner.height - 4), with: colors.itemForeground)
        }
    }
}
