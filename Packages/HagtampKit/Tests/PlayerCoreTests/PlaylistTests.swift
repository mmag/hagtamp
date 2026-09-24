import Foundation
import Testing

@testable import PlayerCore

@Suite struct PlaylistTests {
    func playlist(_ names: [String]) -> Playlist {
        var p = Playlist()
        p.insert(names.map { TrackInfo(url: URL(fileURLWithPath: "/music/\($0).mp3"), duration: 60) })
        return p
    }

    func names(_ p: Playlist) -> [String] { p.entries.map { $0.url.deletingPathExtension().lastPathComponent } }

    @Test func winampSelection() {
        var p = playlist(["a", "b", "c", "d", "e"])
        p.select(1)
        p.extendSelection(to: 3)
        #expect(p.selectedIndices == [1, 2, 3])
        p.toggleSelection(2)  // deselects, but becomes the anchor
        #expect(p.selectedIndices == [1, 3])
        p.extendSelection(to: 4)
        #expect(p.selectedIndices == [2, 3, 4])
        p.invertSelection()
        #expect(p.selectedIndices == [0, 1])
    }

    @Test func draggingMovesTheSelectionWithinBounds() {
        var p = playlist(["a", "b", "c", "d", "e"])
        p.select(1)
        p.toggleSelection(3)
        #expect(p.moveSelection(by: 1) == 1)
        #expect(names(p) == ["a", "c", "b", "e", "d"])
        #expect(p.moveSelection(by: 5) == 0)  // "d" is already last
        // Selected entries keep their spacing while moving.
        #expect(p.moveSelection(by: -10) == -2)
        #expect(names(p) == ["b", "a", "d", "c", "e"])
        #expect(p.selectedIndices == [0, 2])
    }

    @Test func currentTrackSurvivesEdits() {
        var p = playlist(["b", "a", "c"])
        p.setCurrent(0)  // "b"
        p.sort(by: .fileName)
        #expect(names(p) == ["a", "b", "c"])
        #expect(p.currentIndex == 1)
        p.select(1)
        p.removeSelected()
        #expect(p.currentIndex == nil)
        #expect(names(p) == ["a", "c"])
    }

    @Test func cropDuplicatesAndDeadFiles() {
        var p = playlist(["a", "b", "a", "c"])
        p.removeDuplicates()
        #expect(names(p) == ["a", "b", "c"])
        p.removeDeadFiles { $0.lastPathComponent != "b.mp3" }
        #expect(names(p) == ["a", "c"])
        p.select(1)
        p.crop()
        #expect(names(p) == ["c"])
    }

    @Test func naturalSortAndInsert() {
        var p = playlist(["track10", "Track2", "track1"])
        p.sort(by: .title)
        #expect(names(p) == ["track1", "Track2", "track10"])
        p.insert([TrackInfo(url: URL(fileURLWithPath: "/x.mp3"))], at: 1)
        #expect(names(p) == ["track1", "x", "Track2", "track10"])
    }

    @Test func runningTimeFlagsUnknownLengths() {
        var p = playlist(["a", "b"])
        p.insert([TrackInfo(url: URL(fileURLWithPath: "/stream.mp3"))])
        p.select(0)
        let time = p.runningTime
        #expect(time.selected == 60 && time.total == 120 && time.incomplete)
    }
}

@Suite struct PlaylistFileTests {
    let base = URL(fileURLWithPath: "/music/lists")

    @Test func m3uWithExtinfAndRelativePaths() {
        let text = """
            #EXTM3U
            #EXTINF:191,Marilyn Manson - Rock Is Dead
            ../Rock Is Dead.mp3
            #EXTINF:-1,Radio
            http://example.com/stream
            C:\\Music\\old.mp3
            /abs/song.flac
            """
        let tracks = PlaylistFile.parse(Data(text.utf8), base: base)
        #expect(tracks.count == 4)
        #expect(tracks[0].url.path == "/music/Rock Is Dead.mp3")
        #expect(tracks[0].displayName == "Marilyn Manson - Rock Is Dead")
        #expect(tracks[0].duration == 191)
        #expect(tracks[1].url.absoluteString == "http://example.com/stream")
        #expect(tracks[1].duration == nil)
        #expect(tracks[3].url.path == "/abs/song.flac")
    }

    @Test func pls() {
        let text = """
            [playlist]
            File2=b.mp3
            File1=a.mp3
            Title1=Song A
            Length1=100
            NumberOfEntries=2
            Version=2
            """
        let tracks = PlaylistFile.parse(Data(text.utf8), base: base)
        #expect(tracks.map(\.url.lastPathComponent) == ["a.mp3", "b.mp3"])
        #expect(tracks[0].displayName == "Song A" && tracks[0].duration == 100)
    }

    @Test func ansiM3U() {
        var data = Data("#EXTINF:10,Bj".utf8)
        data.append(0xF6)  // ö in Windows-1252
        data.append(contentsOf: Array("rk\nsong.mp3\n".utf8))
        #expect(PlaylistFile.parse(data, base: base).first?.displayName == "Björk")
    }

    @Test func writeAndReadBack() {
        let tracks = [
            TrackInfo(url: URL(fileURLWithPath: "/music/lists/sub/a.mp3"), title: "A", artist: "X", duration: 61.4),
            TrackInfo(url: URL(fileURLWithPath: "/elsewhere/b.mp3")),
        ]
        for format in [PlaylistFile.Format.m3u8, .pls] {
            let data = PlaylistFile.data(for: tracks, format: format, base: base)
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains("sub/a.mp3") && !text.contains("/music/lists/sub"))
            let back = PlaylistFile.parse(data, base: base)
            #expect(back.map(\.url.path) == tracks.map(\.url.path))
            #expect(back[0].displayName == "X - A" && back[0].duration == 61)
        }
    }
}
