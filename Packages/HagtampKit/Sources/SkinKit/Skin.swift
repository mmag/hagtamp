import Foundation

/// A classic Winamp skin, fully decoded.
///
/// Missing or unreadable bitmaps fall back to the base skin (Winamp 2.91), as
/// Winamp does. Text files fall back to built-in defaults, and a missing
/// `region.txt` means rectangular windows.
public struct Skin: Sendable {
    public var name: String
    public var sheets: [SkinSheet: Bitmap]
    public var visColors: [PixelColor]
    public var playlistStyle: PlaylistStyle
    public var regions: SkinRegions
    /// Cursors the skin provides; others show the system arrow (never inherited).
    public var cursors: [SkinCursorName: SkinCursor]
    /// Sheets the skin lacks, taken from the base skin instead.
    public var inheritedSheets: Set<SkinSheet>
    /// Problems found while loading; the skin is still usable.
    public var warnings: [String]

    /// Whether time digits come from NUMS_EX.BMP (which has a 9x13 minus sign).
    public var usesNumsEx: Bool { sheets[.numsEx] != nil }

    /// Skins without BALANCE.BMP draw the balance slider from their own VOLUME.BMP.
    public var balanceUsesVolume: Bool {
        inheritedSheets.contains(.balance) && !inheritedSheets.contains(.volume)
    }

    public func bitmap(_ sheet: SkinSheet) -> Bitmap? { sheets[sheet] }

    /// Loads a skin; missing bitmaps come from `fallback` (the bundled default skin).
    public static func load(contentsOf url: URL, fallback: Skin = .base) throws -> Skin {
        let archive = try SkinArchive(contentsOf: url)
        return Skin(archive: archive, name: url.deletingPathExtension().lastPathComponent, fallback: fallback)
    }

    public static func load(zipData: Data, name: String) throws -> Skin {
        Skin(archive: try SkinArchive(zipData: zipData), name: name, fallback: .base)
    }

    /// The default skin bundled with the app: the Winamp 2.91 base skin with
    /// Hagtamp's name in the title bars (scripts/retitle_base_skin.py).
    public static let base: Skin = {
        let url = Bundle.module.url(forResource: "hagtamp-base", withExtension: "wsz")!
        let archive = try! SkinArchive(contentsOf: url)
        let skin = Skin(archive: archive, name: "Base Skin", fallback: nil)
        precondition(skin.warnings.isEmpty, "Bundled base skin is incomplete: \(skin.warnings)")
        return skin
    }()

    public init(archive: SkinArchive, name: String, fallback: Skin?) {
        self.name = name
        var sheets: [SkinSheet: Bitmap] = [:]
        var inherited: Set<SkinSheet> = []
        var warnings: [String] = []

        for sheet in SkinSheet.allCases {
            if let entry = archive.file(sheet.rawValue, extensions: ["bmp", "png"]) {
                if let bitmap = Self.decodeImage(entry.data) {
                    sheets[sheet] = bitmap
                    continue
                }
                warnings.append("\(entry.path): unreadable image")
            } else if sheet != .numsEx {
                warnings.append("\(sheet.rawValue).BMP missing")
            }
            // NUMS_EX is an optional override of the skin's own NUMBERS, never inherited.
            if sheet != .numsEx, let fallbackSheet = fallback?.sheets[sheet] {
                sheets[sheet] = fallbackSheet
                inherited.insert(sheet)
            }
        }

        self.sheets = sheets
        inheritedSheets = inherited
        visColors = archive.text("VISCOLOR").map(VisColors.parse) ?? VisColors.default
        playlistStyle = archive.text("PLEDIT").map(PlaylistStyle.parse) ?? .default
        regions = archive.text("REGION").map(SkinRegions.parse) ?? SkinRegions()
        var cursors: [SkinCursorName: SkinCursor] = [:]
        for name in SkinCursorName.allCases {
            guard let entry = archive.file(name.rawValue, extensions: ["cur", "ani"]) else { continue }
            if let cursor = CursorDecoder.decode(entry.data) {
                cursors[name] = cursor
            } else {
                warnings.append("\(entry.path): unreadable cursor")
            }
        }
        self.cursors = cursors
        self.warnings = warnings
    }

    /// BMP through our own decoder (exact colours, GDI leniency); anything else
    /// (PNG, which WACUP allows, or a mislabelled file) through ImageIO.
    static func decodeImage(_ data: Data) -> Bitmap? {
        if let bitmap = try? BMPDecoder.decode(data) { return bitmap }
        return Bitmap(imageData: data)
    }
}
