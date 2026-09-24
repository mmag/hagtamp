import Foundation

/// The 5x6 bitmap font of TEXT.BMP used by the marquee, kbps/kHz and playlist
/// time displays.
///
/// The glyph layout follows Webamp's FONT_LOOKUP (MIT, see
/// THIRD_PARTY_NOTICES.md). Unlike Webamp, Å/Ö/Ä keep their own glyphs, and
/// characters without a glyph are drawn as spaces.
public enum SkinFont {
    public static let glyphWidth = 5
    public static let glyphHeight = 6

    public static func sprite(for character: Character) -> Sprite {
        let (row, column) = position(for: character)
        return Sprite(.text, column * glyphWidth, row * glyphHeight, glyphWidth, glyphHeight)
    }

    static func position(for character: Character) -> (row: Int, column: Int) {
        let upper = Character(String(character).uppercased())
        if let position = lookup[upper] { return position }
        let folded = String(upper).folding(options: .diacriticInsensitive, locale: nil)
        if folded.count == 1, let position = lookup[Character(folded)] { return position }
        return space
    }

    private static let space = (row: 0, column: 30)

    private static let lookup: [Character: (row: Int, column: Int)] = {
        var table: [Character: (Int, Int)] = [:]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@".enumerated() { table[c] = (0, i) }
        table[" "] = space
        for (i, c) in "0123456789\u{2026}.:()-'!_+\\/[]^&%,=$#".enumerated() { table[c] = (1, i) }
        for (i, c) in "ÅÖÄ?*".enumerated() { table[c] = (2, i) }
        table["<"] = table["["]
        table[">"] = table["]"]
        table["{"] = table["["]
        table["}"] = table["]"]
        return table
    }()
}
