import Testing

@testable import PlayerCore

/// Made-up words: the parser only cares about the stamps around them.
@Suite struct LyricsTests {
    @Test func lrcLinesWithTheirTimes() throws {
        let lyrics = try #require(Lyrics.parse("""
            [ti:Test Tone]
            [ar:Nobody]
            [00:01.50]first test line
            [00:04.00][00:12.25]a line that comes back
            [00:08:5]third, with a colon stamp
            [00:16.000]
            """))
        #expect(lyrics.isSynced)
        #expect(lyrics.lines.map(\.start) == [1.5, 4, 8.5, 12.25, 16])
        #expect(lyrics.lines.map(\.text) == ["first test line", "a line that comes back", "third, with a colon stamp", "a line that comes back", ""])
        #expect(lyrics.lineIndex(at: 0.5) == nil)
        #expect(lyrics.lineIndex(at: 4) == 1)
        #expect(lyrics.lineIndex(at: 13) == 3)
    }

    @Test func offsetMovesTheWordsEarlier() throws {
        let lyrics = try #require(Lyrics.parse("[offset:+500]\n[00:02.00]early\n[00:00.20]start"))
        #expect(lyrics.lines.map(\.start) == [0, 1.5])
    }

    @Test func plainTextStaysPlain() throws {
        let lyrics = try #require(Lyrics.parse("\n\nverse one\nverse two\n\nchorus [loud]\n\n"))
        #expect(!lyrics.isSynced)
        #expect(lyrics.lines.map(\.text) == ["verse one", "verse two", "", "chorus [loud]"])
        #expect(Lyrics.parse("  \n ") == nil)
    }
}
