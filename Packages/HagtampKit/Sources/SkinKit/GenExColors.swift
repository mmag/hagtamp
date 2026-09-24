/// Colours of generic-window content (media library lists, buttons,
/// scrollbars), read from GENEX.BMP's first row: one pixel every 2 px from
/// x = 48. Order and meaning from Winamp 5's skinning docs (via Webamp).
public struct GenExColors: Sendable, Equatable {
    public var itemBackground: PixelColor
    public var itemForeground: PixelColor
    public var windowBackground: PixelColor
    public var buttonText: PixelColor
    public var windowText: PixelColor
    public var divider: PixelColor
    public var playlistSelection: PixelColor
    public var listHeaderBackground: PixelColor
    public var listHeaderText: PixelColor
    public var listHeaderFrameTopLeft: PixelColor
    public var listHeaderFrameBottomRight: PixelColor
    public var listHeaderFramePressed: PixelColor
    public var listHeaderDeadArea: PixelColor
    public var scrollbar1: PixelColor
    public var scrollbar2: PixelColor
    public var scrollbarPressed1: PixelColor
    public var scrollbarPressed2: PixelColor
    public var scrollbarDeadArea: PixelColor
    /// Selected rows of the focused list.
    public var listTextHighlighted: PixelColor
    public var listTextHighlightedBackground: PixelColor
    /// Selected rows of other lists.
    public var listTextSelected: PixelColor
    public var listTextSelectedBackground: PixelColor

    public init(genex: Bitmap) {
        func color(_ index: Int) -> PixelColor? {
            let x = 48 + index * 2
            return x < genex.width ? genex[x, 0] : nil
        }
        // Old skins define only the first 18; the rest is the sheet's background there.
        let sheetBackground = genex[genex.width - 1, 0]
        func defined(_ index: Int) -> PixelColor? {
            color(index).flatMap { $0 == sheetBackground ? nil : $0 }
        }
        let fallback = PixelColor.black
        itemBackground = color(0) ?? fallback
        itemForeground = color(1) ?? PixelColor(rgb: 0x00FF00)
        windowBackground = color(2) ?? fallback
        buttonText = color(3) ?? fallback
        windowText = color(4) ?? PixelColor(rgb: 0xFFFFFF)
        divider = color(5) ?? PixelColor(rgb: 0x808080)
        playlistSelection = color(6) ?? PixelColor(rgb: 0x0000C6)
        listHeaderBackground = color(7) ?? fallback
        listHeaderText = color(8) ?? PixelColor(rgb: 0xFFFFFF)
        listHeaderFrameTopLeft = color(9) ?? fallback
        listHeaderFrameBottomRight = color(10) ?? fallback
        listHeaderFramePressed = color(11) ?? fallback
        listHeaderDeadArea = color(12) ?? fallback
        scrollbar1 = color(13) ?? fallback
        scrollbar2 = color(14) ?? fallback
        scrollbarPressed1 = color(15) ?? fallback
        scrollbarPressed2 = color(16) ?? fallback
        scrollbarDeadArea = color(17) ?? fallback
        listTextHighlighted = defined(18) ?? itemForeground
        listTextHighlightedBackground = defined(19) ?? playlistSelection
        listTextSelected = defined(20) ?? itemForeground
        listTextSelectedBackground = defined(21) ?? divider
    }
}

extension Skin {
    public var genExColors: GenExColors? {
        bitmap(.genex).map(GenExColors.init(genex:))
    }
}
