import Foundation
import Testing

@testable import SkinKit

@Suite struct ConfigFileTests {
    @Test func iniIsCaseInsensitiveAndFirstKeyWins() {
        let ini = IniFile.parse("""
            ; comment
            [Text]
            Normal = #00FF00
            normal=#FF0000
              Font="Tahoma"
            [text]
            Current=#FFFFFF
            """)
        #expect(ini["text"]?["normal"] == "#00FF00")
        #expect(ini["text"]?["font"] == "Tahoma")
        #expect(ini["text"]?["current"] == "#FFFFFF")
    }

    @Test func playlistColorsTolerateJunk() {
        let style = PlaylistStyle.parse("""
            [Text]
            Normal=00FF00
            Current=#FFFFFF00
            NormalBG=#12
            SelectedBG=#0000C6 ; selection
            Font=Arial Narrow
            """)
        #expect(style.normal == PixelColor(rgb: 0x00FF00))
        #expect(style.current == PixelColor(rgb: 0xFFFFFF))
        #expect(style.normalBackground == PlaylistStyle.default.normalBackground)
        #expect(style.selectedBackground == PixelColor(rgb: 0x0000C6))
        #expect(style.font == "Arial Narrow")
    }

    /// Skins come from Windows: "\r\n" is a single Swift Character and must still split lines.
    @Test func parsesCRLFFiles() {
        let style = PlaylistStyle.parse("[Text]\r\nNormal=#C8C4C8\r\nNormalBG=#404040\r\n")
        #expect(style.normal == PixelColor(rgb: 0xC8C4C8))
        #expect(style.normalBackground == PixelColor(rgb: 0x404040))
        #expect(VisColors.parse("1,2,3\r\n4,5,6\r\n")[1] == PixelColor(r: 4, g: 5, b: 6))
    }

    @Test func missingTextSectionGivesDefaults() {
        #expect(PlaylistStyle.parse("Normal=#123456") == .default)
    }

    @Test func visColorsParseLeadingTriples() {
        let colors = VisColors.parse("""
            0,0,0, // background
            24 33 41 // dots
            not a color
            300,1,2,
            """)
        #expect(colors[0] == PixelColor(rgb: 0))
        #expect(colors[1] == PixelColor(r: 24, g: 33, b: 41))
        #expect(colors[2] == PixelColor(r: 255, g: 1, b: 2))
        #expect(colors[3] == VisColors.default[3])
        #expect(colors.count == 24)
    }

    @Test func regionsSkipDegenerateAndIncompletePolygons() {
        let regions = SkinRegions.parse("""
            [Normal]
            NumPoints=4,2,4
            PointList=0,0, 275,0, 275,116, 0,116,  1,1, 2,2,  5 5 6 5 6 6
            [WindowShade]
            NumPoints=4
            PointList=0,0,275,0,275,14,0,14
            """)
        #expect(regions.main?.count == 1)
        #expect(regions.main?.first?.count == 4)
        #expect(regions.mainShade?.first?[2] == SkinRegions.Point(x: 275, y: 14))
        #expect(regions.equalizer == nil)
    }

    @Test func regionMaskCoversExactPixels() {
        let rect: SkinRegions.Polygon = [.init(x: 1, y: 1), .init(x: 4, y: 1), .init(x: 4, y: 3), .init(x: 1, y: 3)]
        let mask = SkinRegions.mask([rect], width: 5, height: 4)
        let covered = mask.indices.filter { mask[$0] }.map { ($0 % 5, $0 / 5) }
        #expect(covered.map(\.0) == [1, 2, 3, 1, 2, 3])
        #expect(covered.map(\.1) == [1, 1, 1, 2, 2, 2])
    }
}

@Suite struct SkinLoadingTests {
    private func archive(_ files: [String: Data]) -> SkinArchive {
        SkinArchive(entries: files.sorted { $0.key < $1.key }.map { SkinArchive.Entry(path: $0.key, data: $0.value) })
    }

    @Test func lookupIgnoresCaseAndFolders() {
        let archive = SkinArchive(entries: [
            .init(path: "MySkin/Main.BMP", data: Data([1])),
            .init(path: "other/main.bmp", data: Data([2])),
            .init(path: "pledit.txt", data: Data([3])),
        ])
        #expect(archive.file("MAIN", extensions: ["bmp", "png"])?.data == Data([2]))
        #expect(archive.file("PLEDIT", extensions: ["txt"])?.data == Data([3]))
        #expect(archive.file("EQMAIN", extensions: ["bmp"]) == nil)
    }

    @Test func baseSkinIsComplete() {
        let base = Skin.base
        #expect(base.warnings.isEmpty)
        #expect(base.sheets.count == SkinSheet.allCases.count - 1)  // no NUMS_EX
        #expect(base.bitmap(.main)?.width == 275)
        #expect(!base.usesNumsEx)
    }

    @Test func missingBitmapsComeFromBaseButNumsExDoesNot() throws {
        let baseMain = try #require(Skin.base.bitmap(.main))
        let numsEx = BMPTestImage.solid(width: 108, height: 13, color: 0x00FF00)
        let skin = Skin(archive: archive(["nums_ex.bmp": numsEx]), name: "test", fallback: .base)
        #expect(skin.bitmap(.main) == baseMain)
        #expect(skin.usesNumsEx)
        #expect(skin.warnings.contains("MAIN.BMP missing"))

        let withoutNumsEx = Skin(archive: archive([:]), name: "empty", fallback: .base)
        #expect(!withoutNumsEx.usesNumsEx)
    }

    @Test func unreadableBitmapFallsBackWithWarning() {
        let skin = Skin(archive: archive(["MAIN.BMP": Data("garbage".utf8)]), name: "broken", fallback: .base)
        #expect(skin.bitmap(.main) == Skin.base.bitmap(.main))
        #expect(skin.warnings.contains("MAIN.BMP: unreadable image"))
    }

    @Test func fontMapsCaseAndDiacritics() {
        #expect(SkinFont.sprite(for: "a") == SkinFont.sprite(for: "A"))
        #expect(SkinFont.sprite(for: "é") == SkinFont.sprite(for: "E"))
        #expect(SkinFont.sprite(for: "Ö").rect.y == 12)
        #expect(SkinFont.sprite(for: "~") == SkinFont.sprite(for: " "))
        #expect(SkinFont.sprite(for: "“") == SkinFont.sprite(for: "\""))
        #expect(SkinFont.sprite(for: "’") == SkinFont.sprite(for: "'"))
        #expect(SkinFont.sprite(for: "3").rect == PixelRect(x: 15, y: 6, width: 5, height: 6))
    }
}

enum BMPTestImage {
    /// A 24-bit BMP filled with one colour.
    static func solid(width: Int, height: Int, color: UInt32) -> Data {
        let stride = (width * 3 + 3) / 4 * 4
        var bytes = [UInt8]()
        func u16(_ v: Int) { bytes += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
        bytes += Array("BM".utf8)
        u32(54 + stride * height); u32(0); u32(54)
        u32(40); u32(width); u32(height); u16(1); u16(24); u32(0); u32(stride * height); u32(0); u32(0); u32(0); u32(0)
        for _ in 0..<height {
            for _ in 0..<width { bytes += [UInt8(color & 0xFF), UInt8((color >> 8) & 0xFF), UInt8(color >> 16)] }
            bytes += [UInt8](repeating: 0, count: stride - width * 3)
        }
        return Data(bytes)
    }
}
