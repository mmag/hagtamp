import CoreGraphics
import CoreText
import Foundation
import SkinKit

/// Draws the playlist editor in normal (non-shade) mode at any size.
///
/// The frame is built from PLEDIT.BMP tiles; the track list itself uses the
/// system font named by `pledit.txt`, like Winamp does. Layout from Webamp's
/// playlist-window.css (MIT, see THIRD_PARTY_NOTICES.md).
public enum PlaylistWindowRenderer {
    public static let baseWidth = 275
    public static let baseHeight = 116

    /// Area of the track list, in window coordinates.
    public static func listRect(width: Int, height: Int) -> PixelRect {
        PixelRect(x: 12, y: 20, width: width - 32, height: height - 58)
    }

    public static func visibleRowCount(height: Int, textSize: TextSize = .normal) -> Int {
        max(0, (height - 58 - 6) / textSize.rowHeight)
    }

    public static func render(_ skin: Skin, _ state: PlaylistWindowState) -> Bitmap {
        if state.shade { return renderShade(skin, state) }

        let width = state.pixelWidth, height = state.pixelHeight
        var canvas = Bitmap(width: width, height: height, fill: skin.playlistStyle.normalBackground)

        drawTop(&canvas, skin, state, width: width)
        drawSides(&canvas, skin, state, width: width, height: height)
        drawBottom(&canvas, skin, state, width: width, height: height)
        drawRows(&canvas, skin, state, width: width, height: height)
        if let menu = state.openMenu {
            drawMenu(&canvas, skin, menu, hovered: state.hoveredMenuItem, width: width, height: height)
        }
        return canvas
    }

    private static func drawTop(_ canvas: inout Bitmap, _ skin: Skin, _ state: PlaylistWindowState, width: Int) {
        let active = state.focused
        let tile = active ? Sprite.PlEdit.topTileActive : Sprite.PlEdit.topTile
        // Even width steps need two part-tiles to keep the title centred.
        let spacers = state.widthSteps % 2 == 0
        let fillWidth = (width - 150 - (spacers ? 25 : 0)) / 2

        canvas.draw(skin, active ? Sprite.PlEdit.topLeftActive : Sprite.PlEdit.topLeft, x: 0, y: 0)
        var x = 25
        if spacers {
            canvas.draw(skin, tile, x: x, y: 0, width: 12, height: 20)
            x += 12
        }
        canvas.tile(skin, tile, over: PixelRect(x: x, y: 0, width: fillWidth, height: 20))
        x += fillWidth
        canvas.draw(skin, active ? Sprite.PlEdit.topTitleActive : Sprite.PlEdit.topTitle, x: x, y: 0)
        x += 100
        if spacers {
            canvas.draw(skin, tile, x: x, y: 0, width: 13, height: 20)
            x += 13
        }
        canvas.tile(skin, tile, over: PixelRect(x: x, y: 0, width: fillWidth, height: 20))
        canvas.draw(skin, active ? Sprite.PlEdit.topRightActive : Sprite.PlEdit.topRight, x: width - 25, y: 0)
        if state.pressed == .shade { canvas.draw(skin, Sprite.PlEdit.shadePressed, x: width - 21, y: 3) }
        if state.pressed == .close { canvas.draw(skin, Sprite.PlEdit.closePressed, x: width - 11, y: 3) }
    }

    private static func drawSides(_ canvas: inout Bitmap, _ skin: Skin, _ state: PlaylistWindowState, width: Int, height: Int) {
        let middle = height - 58
        canvas.tile(skin, Sprite.PlEdit.leftTile, over: PixelRect(x: 0, y: 20, width: 12, height: middle))
        canvas.tile(skin, Sprite.PlEdit.rightTile, over: PixelRect(x: width - 20, y: 20, width: 20, height: middle))

        let thumb = state.pressed == .scrollBar ? Sprite.PlEdit.scrollThumbPressed : Sprite.PlEdit.scrollThumb
        let y = PlaylistWindowLayout.scrollBar(height: height).thumbPosition(scrollPosition(state, height: height))
        canvas.draw(skin, thumb, x: width - 15, y: y)
    }

    /// Scroll position 0...1 of the track list.
    public static func scrollPosition(_ state: PlaylistWindowState, height: Int) -> Double {
        let maxFirstRow = maxFirstVisibleRow(rowCount: state.rows.count, height: height)
        return maxFirstRow == 0 ? 0 : Double(min(state.firstVisibleRow, maxFirstRow)) / Double(maxFirstRow)
    }

    public static func maxFirstVisibleRow(rowCount: Int, height: Int) -> Int {
        max(0, rowCount - visibleRowCount(height: height))
    }

    /// The bar and the items of a popped-up bottom menu, stacked upwards from its button.
    private static func drawMenu(_ canvas: inout Bitmap, _ skin: Skin, _ menu: PlaylistMenu, hovered: Int?, width: Int, height: Int) {
        let bar: Sprite
        switch menu {
        case .add: bar = Sprite.PlEdit.addMenuBar
        case .remove: bar = Sprite.PlEdit.removeMenuBar
        case .select: bar = Sprite.PlEdit.selectMenuBar
        case .misc: bar = Sprite.PlEdit.miscMenuBar
        case .list: bar = Sprite.PlEdit.listMenuBar
        }
        let x = PlaylistWindowLayout.menuX(menu, width: width)
        canvas.draw(skin, bar, x: x - 3, y: height - 12 - bar.height)
        for (index, item) in menu.items.enumerated() {
            let rect = PlaylistWindowLayout.menuItemRect(menu, item: index, width: width, height: height)
            let (normal, hover) = sprites(for: item)
            canvas.draw(skin, index == hovered ? hover : normal, x: rect.x, y: rect.y)
        }
    }

    private static func sprites(for item: PlaylistMenuItem) -> (Sprite, Sprite) {
        typealias P = Sprite.PlEdit
        switch item {
        case .addURL: return (P.addURL, P.addURLHover)
        case .addDirectory: return (P.addDir, P.addDirHover)
        case .addFile: return (P.addFile, P.addFileHover)
        case .removeMisc: return (P.removeMisc, P.removeMiscHover)
        case .removeAll: return (P.removeAll, P.removeAllHover)
        case .crop: return (P.crop, P.cropHover)
        case .removeSelected: return (P.removeSelected, P.removeSelectedHover)
        case .invertSelection: return (P.invertSelection, P.invertSelectionHover)
        case .selectNone: return (P.selectNone, P.selectNoneHover)
        case .selectAll: return (P.selectAll, P.selectAllHover)
        case .sortList: return (P.sortList, P.sortListHover)
        case .fileInfo: return (P.fileInfo, P.fileInfoHover)
        case .miscOptions: return (P.miscOptions, P.miscOptionsHover)
        case .newList: return (P.newList, P.newListHover)
        case .saveList: return (P.saveList, P.saveListHover)
        case .loadList: return (P.loadList, P.loadListHover)
        }
    }

    // MARK: - Shade mode

    /// Shade mode: a 14 px strip with the current title and its length.
    private static func renderShade(_ skin: Skin, _ state: PlaylistWindowState) -> Bitmap {
        let width = state.pixelWidth
        var canvas = Bitmap(width: width, height: 14, fill: .black)
        canvas.tile(skin, Sprite.PlEdit.shadeBackground, over: PixelRect(x: 0, y: 0, width: width, height: 14))
        canvas.draw(skin, Sprite.PlEdit.shadeLeft, x: 0, y: 0)
        canvas.draw(skin, state.focused ? Sprite.PlEdit.shadeRightActive : Sprite.PlEdit.shadeRight, x: width - 50, y: 0)

        let maxCharacters = (205 + (width - baseWidth)) / SkinFont.glyphWidth
        var title = state.currentTitle ?? "[No file]"
        if title.count > maxCharacters { title = title.prefix(maxCharacters - 1) + "\u{2026}" }
        canvas.drawText(skin, title, x: 5, y: 4)
        if state.currentTitle != nil {
            let duration = state.currentDuration
            canvas.drawText(skin, duration, x: width - 30 - duration.count * SkinFont.glyphWidth, y: 4)
        }

        if state.pressed == .shade { canvas.draw(skin, Sprite.PlEdit.unshadePressed, x: width - 21, y: 3) }
        if state.pressed == .close { canvas.draw(skin, Sprite.PlEdit.closePressed, x: width - 11, y: 3) }
        return canvas
    }

    private static func drawBottom(_ canvas: inout Bitmap, _ skin: Skin, _ state: PlaylistWindowState, width: Int, height: Int) {
        let top = height - 38
        canvas.tile(skin, Sprite.PlEdit.bottomTile, over: PixelRect(x: 0, y: top, width: width, height: 38))
        canvas.draw(skin, Sprite.PlEdit.bottomLeft, x: 0, y: top)
        let right = width - 150
        canvas.draw(skin, Sprite.PlEdit.bottomRight, x: right, y: top)
        if state.widthSteps > 2 {
            canvas.draw(skin, Sprite.PlEdit.visualizerBackground, x: right - 75, y: top)
        }

        let runningTime = state.runningTime.padding(toLength: 18, withPad: " ", startingAt: 0)
        canvas.drawText(skin, runningTime, x: right + 7, y: top + 10, width: 18 * SkinFont.glyphWidth)

        // Mini time: blank background first, then the characters.
        let miniX = right + 66, miniY = top + 23
        MainWindowRenderer.drawMiniTime(&canvas, skin, state.miniTime, x: miniX, y: miniY)
    }

    private static func drawRows(_ canvas: inout Bitmap, _ skin: Skin, _ state: PlaylistWindowState, width: Int, height: Int) {
        let list = listRect(width: width, height: height)
        let style = skin.playlistStyle
        let textSize = state.textSize, rowHeight = textSize.rowHeight
        let font = CTFontCreateWithName(style.font as CFString, textSize.fontSize, nil)
        let visible = visibleRowCount(height: height, textSize: textSize)
        let rows = state.rows.indices.dropFirst(state.firstVisibleRow).prefix(visible)

        for (line, index) in rows.enumerated() {
            let top = list.y + 3 + line * rowHeight
            if state.selectedRows.contains(index) {
                canvas.fill(PixelRect(x: list.x, y: top, width: list.width, height: rowHeight), with: style.selectedBackground)
            }
        }

        canvas.withCGContext { ctx in
            ctx.setShouldAntialias(false)
            ctx.setShouldSmoothFonts(false)
            ctx.clip(to: CGRect(x: list.x, y: height - list.maxY, width: list.width, height: list.height))
            for (line, index) in rows.enumerated() {
                let row = state.rows[index]
                let color = index == state.currentRow ? style.current : style.normal
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
                ]
                let baseline = CGFloat(height - (list.y + 3 + line * rowHeight + textSize.scaled(10)))

                let duration = CTLineCreateWithAttributedString(NSAttributedString(string: row.duration, attributes: attributes))
                let durationWidth = CTLineGetTypographicBounds(duration, nil, nil, nil)
                let durationX = CGFloat(list.maxX - 3) - ceil(durationWidth)

                ctx.saveGState()
                ctx.clip(to: CGRect(x: CGFloat(list.x), y: baseline - CGFloat(textSize.scaled(4)), width: durationX - CGFloat(list.x) - 2, height: CGFloat(rowHeight)))
                ctx.textPosition = CGPoint(x: CGFloat(list.x + 1), y: baseline)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: row.title, attributes: attributes)), ctx)
                ctx.restoreGState()

                ctx.textPosition = CGPoint(x: durationX, y: baseline)
                CTLineDraw(duration, ctx)
            }
        }
    }
}
