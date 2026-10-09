import Foundation

/// The 5x6 bitmap font of TEXT.BMP used by the marquee, kbps/kHz and playlist
/// time displays.
///
/// The glyph layout follows Webamp's FONT_LOOKUP (MIT, see
/// THIRD_PARTY_NOTICES.md). Unlike Webamp, Å/Ö/Ä keep their own glyphs, and
/// characters without a glyph are drawn as spaces.
///
/// The font has no Cyrillic: capitals that look like Latin ones take the
/// skin's own glyphs, the others are drawn here (`extraGlyph`) in the skin's
/// colours, from masks in the base skin's style.
public enum SkinFont {
    public static let glyphWidth = 5
    public static let glyphHeight = 6

    public static func sprite(for character: Character) -> Sprite {
        let (row, column) = position(for: character)
        return Sprite(.text, column * glyphWidth, row * glyphHeight, glyphWidth, glyphHeight)
    }

    static func position(for character: Character) -> (row: Int, column: Int) {
        let upper = Character(String(character).uppercased())
        if let position = lookup[lookAlikes[upper] ?? upper] { return position }
        let folded = String(upper).folding(options: .diacriticInsensitive, locale: nil)
        if folded.count == 1, let position = lookup[lookAlikes[Character(folded)] ?? Character(folded)] { return position }
        return space
    }

    /// Cyrillic capitals drawn as the Latin ones that look the same.
    static let lookAlikes: [Character: Character] = [
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X", "І": "I",
        "Ј": "J", "Ѕ": "S",
    ]

    /// The mask of a letter TEXT.BMP lacks (Cyrillic), if it is one we draw.
    public static func extraMask(for character: Character) -> [String]? {
        extraMasks[Character(String(character).uppercased())]
    }

    /// The letters TEXT.BMP lacks, 4 pixels wide like its own (5 for the
    /// widest), "#" where the ink goes.
    static let extraMasks: [Character: [String]] = [
        "Б": ["####", "#...", "###.", "#..#", "#..#", "###."],
        "Г": ["####", "#...", "#...", "#...", "#...", "#..."],
        "Д": [".##.", ".#.#", ".#.#", ".#.#", "####", "#..#"],
        "Ж": ["#.#.#", "#.#.#", ".###.", ".###.", "#.#.#", "#.#.#"],
        "З": [".##.", "#..#", "..#.", "...#", "#..#", ".##."],
        "И": ["#..#", "#..#", "#.##", "##.#", "#..#", "#..#"],
        "Й": [".##.", "#..#", "#.##", "##.#", "#..#", "#..#"],
        "Л": [".###", ".#.#", ".#.#", ".#.#", "#..#", "#..#"],
        "П": ["####", "#..#", "#..#", "#..#", "#..#", "#..#"],
        "У": ["#..#", "#..#", "#..#", ".###", "...#", ".##."],
        "Ф": ["..#..", ".###.", "#.#.#", "#.#.#", ".###.", "..#.."],
        "Ц": ["#..#", "#..#", "#..#", "#..#", "####", "...#"],
        "Ч": ["#..#", "#..#", "#..#", ".###", "...#", "...#"],
        "Ш": ["#.#.#", "#.#.#", "#.#.#", "#.#.#", "#.#.#", "#####"],
        "Щ": ["#.#.#", "#.#.#", "#.#.#", "#.#.#", "#####", "....#"],
        "Ъ": ["##..", ".#..", ".###", ".#.#", ".#.#", ".###"],
        "Ы": ["#...#", "#...#", "###.#", "#.#.#", "#.#.#", "###.#"],
        "Ь": ["#...", "#...", "###.", "#..#", "#..#", "###."],
        "Э": [".##.", "#..#", "..##", "...#", "#..#", ".##."],
        "Ю": ["#..#.", "#.#.#", "###.#", "#.#.#", "#.#.#", "#..#."],
        "Я": [".###", "#..#", "#..#", ".###", ".#.#", "#..#"],
        "Є": [".##.", "#..#", "###.", "#...", "#..#", ".##."],
        "Ґ": ["...#", "####", "#...", "#...", "#...", "#..."],
        "Ў": [".##.", "#..#", "#..#", ".###", "...#", ".##."],
    ]

    /// The colours of a skin's font: the background behind a glyph (its
    /// space) and the ink of each row (what its letters mostly use there).
    public struct Palette {
        let background: Bitmap
        let ink: [PixelColor]

        public init(_ text: Bitmap) {
            func pixel(_ x: Int, _ y: Int) -> PixelColor? {
                x < text.width && y < text.height ? text[x, y] : nil
            }
            let (spaceX, spaceY) = (SkinFont.space.column * glyphWidth, SkinFont.space.row * glyphHeight)
            var background = Bitmap(width: glyphWidth, height: glyphHeight, fill: pixel(spaceX, spaceY) ?? PixelColor(rgb: 0))
            for y in 0..<glyphHeight {
                for x in 0..<glyphWidth { if let p = pixel(spaceX + x, spaceY + y) { background[x, y] = p } }
            }
            // Ink: the letters' pixels that differ from the space behind them.
            var counts = [[PixelColor: Int]](repeating: [:], count: glyphHeight)
            for letter in 0..<26 {
                for y in 0..<glyphHeight {
                    for x in 0..<glyphWidth {
                        guard let p = pixel(letter * glyphWidth + x, y), p != background[x, y] else { continue }
                        counts[y][p, default: 0] += 1
                    }
                }
            }
            let rows = counts.map { $0.max { $0.value < $1.value }?.key }
            let overall = counts.reduce(into: [PixelColor: Int]()) { all, row in all.merge(row, uniquingKeysWith: +) }.max { $0.value < $1.value }?.key
            // A row the letters leave empty takes the nearest one's ink.
            ink = (0..<glyphHeight).map { y in
                let nearest = rows.indices.filter { rows[$0] != nil }.min { abs($0 - y) < abs($1 - y) }
                return rows[y] ?? nearest.flatMap { rows[$0] } ?? overall ?? PixelColor(rgb: 0xFFFFFF)
            }
            self.background = background
        }

        /// A glyph from its mask, in these colours.
        public func glyph(_ mask: [String]) -> Bitmap {
            var glyph = background
            for (y, row) in mask.prefix(glyphHeight).enumerated() {
                for (x, c) in row.prefix(glyphWidth).enumerated() where c == "#" { glyph[x, y] = ink[y] }
            }
            return glyph
        }
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
        // Typographic quotes (tags, messages) as the straight ones.
        for c in "\u{201C}\u{201D}\u{201E}\u{00AB}\u{00BB}" { table[c] = table["\""] }
        for c in "\u{2018}\u{2019}" { table[c] = table["'"] }
        return table
    }()
}
