/// The variable-width title font of generic windows (media library, album
/// art), stored in GEN.BMP: letters A–Z in one row for active windows (y 88)
/// and one for inactive ones (y 96), 7 px tall, separated by columns of the
/// row's background colour. Parsing follows Webamp's skinParser (MIT).
public struct GenFont: Sendable {
    public static let height = 7
    public static let spaceWidth = 5

    private let active: [Character: PixelRect]
    private let inactive: [Character: PixelRect]

    public init(gen: Bitmap) {
        active = Self.letters(in: gen, y: 88)
        inactive = Self.letters(in: gen, y: 96)
    }

    public func rect(for character: Character, active isActive: Bool) -> PixelRect? {
        let key = Character(String(character).uppercased())
        return (isActive ? active : inactive)[key]
    }

    /// Width of `text`; letters are set without gaps.
    public func width(of text: String, active isActive: Bool) -> Int {
        text.reduce(0) { sum, c in
            sum + (c == " " ? Self.spaceWidth : rect(for: c, active: isActive)?.width ?? 0)
        }
    }

    private static func letters(in gen: Bitmap, y: Int) -> [Character: PixelRect] {
        guard y + height <= gen.height, gen.width > 1 else { return [:] }
        let background = gen[0, y]
        var result: [Character: PixelRect] = [:]
        var x = 1
        for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            var end = x
            while end < gen.width && gen[end, y] != background { end += 1 }
            result[letter] = PixelRect(x: x, y: y, width: end - x, height: height)
            x = end + 1
            if x >= gen.width { break }
        }
        return result
    }
}

extension Skin {
    /// Title font of generic windows (from GEN.BMP).
    public var genFont: GenFont? {
        bitmap(.gen).map(GenFont.init(gen:))
    }
}
