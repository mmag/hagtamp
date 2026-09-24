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
    public static let rowHeight = 13
    static let fontSize: CGFloat = 9

    /// Area of the track list, in window coordinates.
    public static func listRect(width: Int, height: Int) -> PixelRect {
        PixelRect(x: 12, y: 20, width: width - 32, height: height - 58)
    }

    public static func visibleRowCount(height: Int) -> Int {
        max(0, (height - 58 - 6) / rowHeight)
    }

    public static func render(_ skin: Skin, _ state: PlaylistWindowState) -> Bitmap {
        let width = state.pixelWidth, height = state.pixelHeight
        var canvas = Bitmap(width: width, height: height, fill: skin.playlistStyle.normalBackground)

        drawTop(&canvas, skin, state, width: width)
        drawSides(&canvas, skin, state, width: width, height: height)
        drawBottom(&canvas, skin, state, width: width, height: height)
        drawRows(&canvas, skin, state, width: width, height: height)
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
    }

    private static func drawSides(_ canvas: inout Bitmap, _ skin: Skin, _ state: PlaylistWindowState, width: Int, height: Int) {
        let middle = height - 58
        canvas.tile(skin, Sprite.PlEdit.leftTile, over: PixelRect(x: 0, y: 20, width: 12, height: middle))
        canvas.tile(skin, Sprite.PlEdit.rightTile, over: PixelRect(x: width - 20, y: 20, width: 20, height: middle))

        let travel = middle - 18
        let maxFirstRow = max(0, state.rows.count - visibleRowCount(height: height))
        let scroll = maxFirstRow == 0 ? 0 : Double(min(state.firstVisibleRow, maxFirstRow)) / Double(maxFirstRow)
        canvas.draw(skin, Sprite.PlEdit.scrollThumb, x: width - 15, y: 20 + Int(Double(travel) * scroll))
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
        let slots = [1, 7, 12, 20, 25]
        for slot in slots { canvas.drawText(skin, " ", x: miniX + slot, y: miniY) }
        if let time = state.miniTime {
            let digits = time.digits.map(String.init)
            let characters = [time.mode == .remaining ? "-" : " "] + digits
            for (character, slot) in zip(characters, slots) {
                canvas.drawText(skin, character, x: miniX + slot, y: miniY)
            }
        }
    }

    private static func drawRows(_ canvas: inout Bitmap, _ skin: Skin, _ state: PlaylistWindowState, width: Int, height: Int) {
        let list = listRect(width: width, height: height)
        let style = skin.playlistStyle
        let font = CTFontCreateWithName(style.font as CFString, fontSize, nil)
        let visible = visibleRowCount(height: height)
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
                let baseline = CGFloat(height - (list.y + 3 + line * rowHeight + 10))

                let duration = CTLineCreateWithAttributedString(NSAttributedString(string: row.duration, attributes: attributes))
                let durationWidth = CTLineGetTypographicBounds(duration, nil, nil, nil)
                let durationX = CGFloat(list.maxX - 3) - ceil(durationWidth)

                ctx.saveGState()
                ctx.clip(to: CGRect(x: CGFloat(list.x), y: baseline - 4, width: durationX - CGFloat(list.x) - 2, height: CGFloat(rowHeight)))
                ctx.textPosition = CGPoint(x: CGFloat(list.x + 1), y: baseline)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: row.title, attributes: attributes)), ctx)
                ctx.restoreGState()

                ctx.textPosition = CGPoint(x: durationX, y: baseline)
                CTLineDraw(duration, ctx)
            }
        }
    }
}
