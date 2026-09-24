import Foundation
import Testing

@testable import SkinKit

/// Builds BMP files byte by byte.
private struct BMPWriter {
    var width: Int
    var height: Int
    var bpp: Int
    var compression = 0
    var palette: [UInt32] = []
    var topDown = false
    var pixelData: [UInt8]

    var data: Data {
        var header = [UInt8]()
        func u16(_ v: Int) { header += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
        let offset = 14 + 40 + palette.count * 4
        header += Array("BM".utf8)
        u32(offset + pixelData.count)
        u32(0)
        u32(offset)
        u32(40)
        u32(width)
        u32(topDown ? -height : height)
        u16(1)
        u16(bpp)
        u32(compression)
        u32(pixelData.count)
        u32(2835)
        u32(2835)
        u32(palette.count)
        u32(0)
        for color in palette {
            header += [UInt8(color & 0xFF), UInt8((color >> 8) & 0xFF), UInt8((color >> 16) & 0xFF), 0]
        }
        return Data(header + pixelData)
    }
}

@Suite struct BMPDecoderTests {
    @Test func decodes8BitBottomUp() throws {
        // 2x2, rows stored bottom-up and padded to 4 bytes.
        let bmp = BMPWriter(
            width: 2, height: 2, bpp: 8, palette: [0xFF0000, 0x00FF00, 0x0000FF],
            pixelData: [2, 1, 0, 0, 0, 1, 0, 0])
        let bitmap = try BMPDecoder.decode(bmp.data)
        #expect(bitmap[0, 0] == PixelColor(rgb: 0xFF0000))
        #expect(bitmap[1, 0] == PixelColor(rgb: 0x00FF00))
        #expect(bitmap[0, 1] == PixelColor(rgb: 0x0000FF))
        #expect(bitmap[1, 1] == PixelColor(rgb: 0x00FF00))
    }

    @Test func decodes24BitTopDown() throws {
        let bmp = BMPWriter(
            width: 1, height: 2, bpp: 24, topDown: true,
            pixelData: [0x33, 0x22, 0x11, 0, 0x66, 0x55, 0x44, 0])
        let bitmap = try BMPDecoder.decode(bmp.data)
        #expect(bitmap[0, 0] == PixelColor(rgb: 0x112233))
        #expect(bitmap[0, 1] == PixelColor(rgb: 0x445566))
    }

    @Test func decodes1And4Bit() throws {
        let mono = BMPWriter(width: 3, height: 1, bpp: 1, palette: [0x000000, 0xFFFFFF], pixelData: [0b1010_0000, 0, 0, 0])
        let one = try BMPDecoder.decode(mono.data)
        #expect((0..<3).map { one[$0, 0] } == [.init(rgb: 0xFFFFFF), .init(rgb: 0), .init(rgb: 0xFFFFFF)])

        let nibbles = BMPWriter(width: 3, height: 1, bpp: 4, palette: [0x000000, 0x111111, 0x222222], pixelData: [0x21, 0x00, 0, 0])
        let four = try BMPDecoder.decode(nibbles.data)
        #expect((0..<3).map { four[$0, 0] } == [.init(rgb: 0x222222), .init(rgb: 0x111111), .init(rgb: 0)])
    }

    @Test func ignoresAlphaOf32BitImages() throws {
        let bmp = BMPWriter(width: 1, height: 1, bpp: 32, pixelData: [0x03, 0x02, 0x01, 0x00])
        #expect(try BMPDecoder.decode(bmp.data)[0, 0] == PixelColor(rgb: 0x010203))
    }

    @Test func decodesRLE8() throws {
        // Row 0 (bottom): run of 3 x index 1; end of line. Row 1: absolute 0,1,0 then end of bitmap.
        let bmp = BMPWriter(
            width: 3, height: 2, bpp: 8, compression: 1, palette: [0x000000, 0xFFFFFF],
            pixelData: [3, 1, 0, 0, 0, 3, 0, 1, 0, 0, 0, 1])
        let bitmap = try BMPDecoder.decode(bmp.data)
        #expect(bitmap[0, 1] == PixelColor(rgb: 0xFFFFFF))
        #expect(bitmap[2, 1] == PixelColor(rgb: 0xFFFFFF))
        #expect(bitmap[0, 0] == PixelColor(rgb: 0))
        #expect(bitmap[1, 0] == PixelColor(rgb: 0xFFFFFF))
    }

    @Test func toleratesTruncatedPixelData() throws {
        var bmp = BMPWriter(width: 2, height: 2, bpp: 24, pixelData: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0])
        bmp.pixelData = Array(bmp.pixelData.prefix(8))  // bottom row only
        let bitmap = try BMPDecoder.decode(bmp.data)
        #expect(bitmap[0, 1] == PixelColor(rgb: 0xFFFFFF))
        #expect(bitmap[0, 0] == .black)
    }

    @Test func rejectsNonBMP() {
        #expect(throws: BMPDecoder.Failure.self) { try BMPDecoder.decode(Data("PNG".utf8)) }
    }

    @Test func rleDeltaMovesDownFromCurrentPosition() throws {
        // Delta (1, 1) from (0, bottom row), then one pixel: lands at (1, row above), per the BMP spec.
        let bmp = BMPWriter(
            width: 2, height: 2, bpp: 8, compression: 1, palette: [0x000000, 0xFFFFFF],
            pixelData: [0, 2, 1, 1, 1, 1, 0, 1])
        let bitmap = try BMPDecoder.decode(bmp.data)
        #expect(bitmap[1, 0] == PixelColor(rgb: 0xFFFFFF))
        #expect(bitmap[1, 1] == PixelColor(rgb: 0))
    }

    /// Our decoder must agree with ImageIO on every bitmap of the base skin,
    /// except GEN.BMP: ImageIO applies the vertical part of RLE deltas one row
    /// late (misplacing the bottom-fill tile), we follow the BMP spec.
    @Test func matchesImageIOOnBaseSkin() throws {
        let url = try #require(Bundle.module.url(forResource: "base-2.91", withExtension: "wsz", subdirectory: "Fixtures"))
        let archive = try SkinArchive(contentsOf: url)
        for entry in archive.entries where entry.path.lowercased().hasSuffix(".bmp") && entry.path != "GEN.BMP" {
            let ours = try BMPDecoder.decode(entry.data)
            let reference = try #require(Bitmap(imageData: entry.data))
            #expect(firstDifference(ours, reference) == nil, "\(entry.path)")
        }
    }
}

/// Describes the first pixel where two bitmaps differ (keeps failure output readable).
func firstDifference(_ a: Bitmap, _ b: Bitmap) -> String? {
    guard a.width == b.width, a.height == b.height else {
        return "size \(a.width)x\(a.height) vs \(b.width)x\(b.height)"
    }
    guard let i = a.pixels.indices.first(where: { a.pixels[$0] != b.pixels[$0] }) else { return nil }
    let count = a.pixels.indices.filter { a.pixels[$0] != b.pixels[$0] }.count
    return "\(count) pixels differ, first at (\(i % a.width),\(i / a.width)): \(PixelColor(argb: a.pixels[i])) vs \(PixelColor(argb: b.pixels[i]))"
}
