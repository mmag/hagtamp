import Foundation

/// Minimal parser for the INI dialect of `pledit.txt` and `region.txt`.
///
/// Mirrors the Win32 profile API Winamp reads them with: section and key names
/// are case-insensitive, whitespace around names and values is trimmed, lines
/// starting with `;` are comments and the first occurrence of a key wins.
enum IniFile {
    typealias Sections = [String: [String: String]]

    static func parse(_ text: String) -> Sections {
        var sections: Sections = [:]
        var current: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let name = line[line.index(after: line.startIndex)..<close]
                    .trimmingCharacters(in: .whitespaces).lowercased()
                current = name
                if sections[name] == nil { sections[name] = [:] }
                continue
            }
            guard let section = current, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if sections[section]?[key] == nil { sections[section]?[key] = value }
        }
        return sections
    }
}

/// Colours of the playlist editor, from `pledit.txt`.
public struct PlaylistStyle: Sendable, Equatable {
    public var normal: PixelColor
    public var current: PixelColor
    public var normalBackground: PixelColor
    public var selectedBackground: PixelColor
    public var font: String
    /// Minibrowser colours; absent in most skins.
    public var minibrowserForeground: PixelColor?
    public var minibrowserBackground: PixelColor?

    public static let `default` = PlaylistStyle(
        normal: PixelColor(rgb: 0x00FF00),
        current: PixelColor(rgb: 0xFFFFFF),
        normalBackground: PixelColor(rgb: 0x000000),
        selectedBackground: PixelColor(rgb: 0x0000FF),
        font: "Arial")

    public static func parse(_ text: String) -> PlaylistStyle {
        var style = PlaylistStyle.default
        guard let section = IniFile.parse(text)["text"] else { return style }
        func color(_ key: String) -> PixelColor? { section[key].flatMap(parseColor) }
        style.normal = color("normal") ?? style.normal
        style.current = color("current") ?? style.current
        style.normalBackground = color("normalbg") ?? style.normalBackground
        style.selectedBackground = color("selectedbg") ?? style.selectedBackground
        style.minibrowserForeground = color("mbfg")
        style.minibrowserBackground = color("mbbg")
        if let font = section["font"], !font.isEmpty { style.font = font }
        return style
    }

    /// `#RRGGBB`, with or without `#`. Skins in the wild append junk after the
    /// six digits, so only the leading hex digits count.
    static func parseColor(_ string: String) -> PixelColor? {
        let hex = string.drop { $0 == "#" || $0 == " " }.prefix { $0.isHexDigit }.prefix(6)
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return PixelColor(rgb: value)
    }
}

/// The 24 visualisation colours from `viscolor.txt`.
///
/// 0: background, 1: dots, 2–17: spectrum bars top to bottom,
/// 18–22: oscilloscope, 23: analyzer peaks.
public enum VisColors {
    public static let count = 24

    public static let `default`: [PixelColor] = [
        0x000000, 0x182129, 0xEF3110, 0xCE2910, 0xD65A00, 0xD66600, 0xD67300, 0xC67B08,
        0xDEA518, 0xD6B521, 0xBDDE29, 0x94DE21, 0x29CE10, 0x32BE10, 0x39B510, 0x319C08,
        0x299400, 0x188408, 0xFFFFFF, 0xD6D6DE, 0xB5BDBD, 0xA0AAAF, 0x949CA5, 0x969696,
    ].map(PixelColor.init(rgb:))

    /// Each line starting with three numbers (commas optional) is the next colour;
    /// everything after them (usually a `//` comment) is ignored.
    public static func parse(_ text: String) -> [PixelColor] {
        var colors = Self.default
        var index = 0
        for line in text.split(whereSeparator: \.isNewline) where index < count {
            guard let rgb = leadingTriple(line) else { continue }
            colors[index] = PixelColor(r: rgb.0, g: rgb.1, b: rgb.2)
            index += 1
        }
        return colors
    }

    private static func leadingTriple(_ line: Substring) -> (UInt8, UInt8, UInt8)? {
        var numbers: [UInt8] = []
        var rest = line.drop { $0 == " " || $0 == "\t" }
        while numbers.count < 3 {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty else { return nil }
            numbers.append(UInt8(min(255, Int(digits.prefix(9)) ?? 255)))
            rest = rest.dropFirst(digits.count).drop { $0 == " " || $0 == "\t" }
            if rest.first == "," { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" } }
        }
        return (numbers[0], numbers[1], numbers[2])
    }
}

/// Window shapes from `region.txt`: polygons in window pixel coordinates.
public struct SkinRegions: Sendable, Equatable {
    public struct Point: Sendable, Hashable {
        public var x: Int
        public var y: Int
    }

    public typealias Polygon = [Point]

    public var main: [Polygon]?
    public var mainShade: [Polygon]?
    public var equalizer: [Polygon]?
    public var equalizerShade: [Polygon]?

    public init(main: [Polygon]? = nil, mainShade: [Polygon]? = nil, equalizer: [Polygon]? = nil, equalizerShade: [Polygon]? = nil) {
        self.main = main
        self.mainShade = mainShade
        self.equalizer = equalizer
        self.equalizerShade = equalizerShade
    }

    public static func parse(_ text: String) -> SkinRegions {
        let ini = IniFile.parse(text)
        func polygons(_ section: String) -> [Polygon]? {
            guard let values = ini[section], let counts = values["numpoints"], let list = values["pointlist"] else {
                return nil
            }
            let separators: (Character) -> Bool = { $0 == "," || $0 == " " || $0 == "\t" }
            let pointCounts = counts.split(whereSeparator: separators).compactMap { Int($0) }
            let coords = list.split(whereSeparator: separators).map { Int($0) ?? 0 }
            let points = stride(from: 0, to: coords.count - 1, by: 2).map { Point(x: coords[$0], y: coords[$0 + 1]) }
            var result: [Polygon] = []
            var at = 0
            for count in pointCounts {
                defer { at += max(0, count) }
                // Degenerate polygons are skipped; authors also declare more points than they list.
                guard count >= 3, at + count <= points.count else { continue }
                result.append(Array(points[at..<at + count]))
            }
            return result.isEmpty ? nil : result
        }
        return SkinRegions(
            main: polygons("normal"),
            mainShade: polygons("windowshade"),
            equalizer: polygons("equalizer"),
            equalizerShade: polygons("equalizerws"))
    }
}
