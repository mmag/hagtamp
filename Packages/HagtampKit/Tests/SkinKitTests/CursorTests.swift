import Foundation
import Testing

@testable import SkinKit

@Suite struct CursorTests {
    @Test func baseSkinCursorsDecode() throws {
        let cursors = Skin.base.cursors
        #expect(cursors.count == 8)
        let normal = try #require(cursors[.titleBar])
        #expect(!normal.isAnimated)
        let frame = normal.frames[0]
        #expect(frame.image.width == 32 && frame.image.height == 32)
        #expect(frame.hotspotX < 32 && frame.hotspotY < 32)
        // The AND mask makes most of a cursor transparent.
        let transparent = frame.image.pixels.filter { $0 >> 24 == 0 }.count
        #expect(transparent > 512)
    }

    @Test func animatedCursorsKeepFramesAndTiming() throws {
        let cur = try #require(Skin.base.cursors[.titleBar]).frames[0]
        let frameData = try #require(Self.curFile(from: "TITLEBAR"))
        var list = Data("fram".utf8)
        for _ in 0..<2 { list += Self.chunk("icon", frameData) }
        var anih = Data(count: 36)
        anih[28] = 6  // display rate: 6 jiffies = 0.1 s
        let body = Data("ACON".utf8) + Self.chunk("anih", anih) + Self.chunk("LIST", list) + Self.chunk("seq ", Data([1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0]))
        let ani = Self.chunk("RIFF", body)

        let cursor = try #require(CursorDecoder.decode(ani))
        #expect(cursor.frames.count == 2)
        #expect(cursor.sequence == [1, 0, 1])
        #expect(cursor.durations == [0.1, 0.1, 0.1])
        #expect(cursor.frames[0].hotspotX == cur.hotspotX)
    }

    static func chunk(_ id: String, _ body: Data) -> Data {
        var data = Data(id.utf8)
        let n = UInt32(body.count)
        data += Data([UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24)])
        data += body
        if body.count % 2 == 1 { data.append(0) }
        return data
    }

    static func curFile(from name: String) -> Data? {
        guard let url = Bundle.module.url(forResource: "base-2.91", withExtension: "wsz", subdirectory: "Fixtures"),
            let archive = try? SkinArchive(contentsOf: url)
        else { return nil }
        return archive.file(name, extensions: ["cur"])?.data
    }
}
