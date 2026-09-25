import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZIPFoundation

@testable import SkinKit

/// Damaged or hostile skin files: they may fail to load, but they must not
/// crash the app or make it allocate gigabytes.
@Suite struct SkinHardeningTests {
    /// A BITMAPINFOHEADER-based BMP header with no pixel data.
    private func bmpHeader(width: Int, height: Int, bpp: Int) -> Data {
        var bytes = [UInt8]()
        func u16(_ v: Int) { bytes += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
        bytes += Array("BM".utf8)
        u32(54)
        u32(0)
        u32(54)
        u32(40)
        u32(width)
        u32(height)
        u16(1)
        u16(bpp)
        u32(0)
        u32(0)
        u32(2835)
        u32(2835)
        u32(0)
        u32(0)
        return Data(bytes)
    }

    @Test func oversizedBitmapsAreRefusedBeforeAllocating() {
        #expect(throws: (any Error).self) { try BMPDecoder.decode(bmpHeader(width: 16384, height: 16384, bpp: 24)) }
        #expect(throws: (any Error).self) { try BMPDecoder.decode(bmpHeader(width: 4096, height: 4096, bpp: 24)) }
        #expect(throws: (any Error).self) { try BMPDecoder.decode(bmpHeader(width: 8000, height: 1, bpp: 24)) }
        // A real-sized one still decodes (its missing pixels are tolerated).
        #expect((try? BMPDecoder.decode(bmpHeader(width: 800, height: 600, bpp: 24)))?.width == 800)
    }

    @Test func oversizedPNGIsRefusedFromItsHeader() throws {
        // A 1x1 PNG whose header then claims 100000 x 100000 pixels.
        let data = NSMutableData()
        let image = Bitmap(width: 1, height: 1, fill: PixelColor(rgb: 0xFF0000)).makeCGImage()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        var png = [UInt8](data as Data)
        #expect(Bitmap(imageData: Data(png)) != nil)
        // IHDR: length (8...11), "IHDR" (12...15), width (16...19), height (20...23), ..., CRC (29...32).
        for (at, value) in [(16, 100_000), (20, 100_000)] {
            png[at] = UInt8(value >> 24 & 0xFF)
            png[at + 1] = UInt8(value >> 16 & 0xFF)
            png[at + 2] = UInt8(value >> 8 & 0xFF)
            png[at + 3] = UInt8(value & 0xFF)
        }
        let crc = Self.crc32(png[12..<29])
        for i in 0..<4 { png[29 + i] = UInt8(crc >> (24 - 8 * i) & 0xFF) }
        #expect(Bitmap(imageData: Data(png)) == nil)
    }

    /// A 32-bit cursor image with alpha whose pixel data stops early.
    @Test func truncatedCursorWithAlphaDoesNotReadPastItsData() {
        var dib = [UInt8]()
        func u16(_ v: Int) { dib += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
        u32(40)
        u32(16)
        u32(32)  // twice the height: colour and mask
        u16(1)
        u16(32)
        for _ in 0..<6 { u32(0) }
        dib += [0, 0, 255, 128, 0, 255, 0, 255]  // two pixels, then nothing
        let bitmap = try? BMPDecoder.decodeIconDIB(Data(dib))
        #expect(bitmap == nil || bitmap?.width == 16)
    }

    @Test func regionNumbersPastAnyWindowAreClamped() {
        let huge = Int.max
        let regions = SkinRegions.parse("""
            [Normal]
            NumPoints=4,\(huge),-5,\(huge)
            PointList=0,0, \(huge),0, \(huge),\(huge), 0,-\(huge), 1,1, 2,2, 3,3
            """)
        let polygon = regions.main?.first
        #expect(regions.main?.count == 1)
        #expect(polygon?.allSatisfy { abs($0.x) <= 65535 && abs($0.y) <= 65535 } == true)
        let mask = SkinRegions.mask(regions.main ?? [], width: 30, height: 20)
        #expect(mask.count == 600)
    }

    @Test func deeplyNestedAnimatedCursorDoesNotExhaustTheStack() throws {
        let frame = try #require(CursorTests.curFile(from: "TITLEBAR"))
        var inner = CursorTests.chunk("icon", frame)
        for _ in 0..<3000 { inner = CursorTests.chunk("LIST", Data("fram".utf8) + inner) }
        let ani = CursorTests.chunk("RIFF", Data("ACON".utf8) + inner)
        #expect(CursorDecoder.decode(ani) == nil || true)  // reaching here is the test
        // Thousands of frames: only the first few dozen are kept.
        var list = Data("fram".utf8)
        for _ in 0..<500 { list += CursorTests.chunk("icon", frame) }
        let many = try #require(CursorDecoder.decode(CursorTests.chunk("RIFF", Data("ACON".utf8) + CursorTests.chunk("LIST", list))))
        #expect(many.frames.count <= 32)
    }

    /// A member that inflates to far more than any skin file is dropped; files a skin doesn't use aren't read.
    @Test func archiveMembersAreCappedAndFiltered() throws {
        let archive = try Archive(data: Data(), accessMode: .create)
        func add(_ path: String, _ data: Data) throws {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        try add("skin/main.bmp", Data(count: SkinArchive.maxFileSize + 1))
        try add("skin/pledit.txt", Data("[Text]\nNormal=#00FF00\n".utf8))
        try add("skin/readme.exe", Data(count: 1000))
        let zip = try #require(archive.data)
        #expect(zip.count < 200_000)  // zeros compress to almost nothing
        let skin = try SkinArchive(zipData: zip)
        #expect(skin.entries.map(\.path) == ["skin/pledit.txt"])
    }

    private static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
