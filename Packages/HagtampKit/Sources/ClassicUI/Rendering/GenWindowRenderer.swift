import SkinKit

public struct GenWindowState: Sendable {
    public var title: String
    public var focused = false
    public var pressed: Control?
    /// Extra size in 25 px (width) and 29 px (height) steps.
    public var widthSteps = 0
    public var heightSteps = 0
    /// Fill of the content area (the window's own content is drawn over it).
    public var contentColor = PixelColor.black

    public init(title: String) {
        self.title = title
    }

    public var pixelWidth: Int { GenWindowRenderer.baseWidth + widthSteps * 25 }
    public var pixelHeight: Int { GenWindowRenderer.baseHeight + heightSteps * 29 }
}

/// Frame of generic windows (album art, later the media library), built
/// from GEN.BMP. Layout from Webamp's gen-window.css (MIT).
public enum GenWindowRenderer {
    public static let baseWidth = 275
    public static let baseHeight = 116

    /// The area left for the window's content.
    public static func contentRect(width: Int, height: Int) -> PixelRect {
        PixelRect(x: 11, y: 20, width: width - 19, height: height - 34)
    }

    public static func render(_ skin: Skin, _ state: GenWindowState) -> Bitmap {
        let w = state.pixelWidth, h = state.pixelHeight
        var canvas = Bitmap(width: w, height: h, fill: state.contentColor)
        let active = state.focused
        typealias G = Sprite.Gen

        // Top: corner, fill, end cap, title, end cap, fill, corner.
        let font = skin.genFont
        let titleWidth = 4 + (font?.width(of: state.title, active: active) ?? 0) + 3
        let fills = max(0, w - 100 - titleWidth)
        let leftFill = fills / 2, rightFill = fills - leftFill
        canvas.tile(skin, active ? G.topCenterFillActive : G.topCenterFill, over: PixelRect(x: 0, y: 0, width: w, height: 20))
        canvas.draw(skin, active ? G.topLeftActive : G.topLeft, x: 0, y: 0)
        canvas.tile(skin, active ? G.topLeftRightFillActive : G.topLeftRightFill, over: PixelRect(x: 25, y: 0, width: leftFill, height: 20))
        canvas.draw(skin, active ? G.topLeftEndActive : G.topLeftEnd, x: 25 + leftFill, y: 0)
        let titleX = 50 + leftFill
        if let font, let gen = skin.bitmap(.gen) {
            var x = titleX + 4
            for character in state.title {
                if character == " " {
                    x += GenFont.spaceWidth
                } else if let rect = font.rect(for: character, active: active) {
                    canvas.draw(gen, from: rect, atX: x, y: 2)
                    x += rect.width
                }
            }
        }
        let rightEndX = titleX + titleWidth
        canvas.draw(skin, active ? G.topRightEndActive : G.topRightEnd, x: rightEndX, y: 0)
        let rightFillRect = PixelRect(x: rightEndX + 25, y: 0, width: rightFill, height: 20)
        canvas.tile(skin, active ? G.topLeftRightFillActive : G.topLeftRightFill, over: rightFillRect, originX: rightFillRect.maxX)
        canvas.draw(skin, active ? G.topRightActive : G.topRight, x: w - 25, y: 0)
        if state.pressed == .close { canvas.draw(skin, G.closePressed, x: w - 11, y: 3) }

        // Sides, with their bottom pieces.
        let middle = PixelRect(x: 0, y: 20, width: w, height: h - 34)
        canvas.tile(skin, G.middleLeft, over: PixelRect(x: 0, y: middle.y, width: 11, height: middle.height))
        canvas.draw(skin, G.middleLeftBottom, x: 0, y: middle.maxY - 24)
        canvas.tile(skin, G.middleRight, over: PixelRect(x: w - 8, y: middle.y, width: 8, height: middle.height))
        canvas.draw(skin, G.middleRightBottom, x: w - 8, y: middle.maxY - 24)

        // Bottom.
        canvas.tile(skin, G.bottomFill, over: PixelRect(x: 0, y: h - 14, width: w, height: 14))
        canvas.draw(skin, G.bottomLeft, x: 0, y: h - 14)
        canvas.draw(skin, G.bottomRight, x: w - 125, y: h - 14)
        return canvas
    }
}

public enum GenWindowLayout {
    public static func regions(width: Int, height: Int) -> [ControlRegion] {
        [
            ControlRegion(.close, width - 11, 3, 9, 9, cursor: .normal),
            ControlRegion(.titleBar, 0, 0, width, 20, .moveWindow, cursor: .normal),
            ControlRegion(.resize, width - 20, height - 20, 20, 20, .press, cursor: .playlistSize),
        ]
    }
}
