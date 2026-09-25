import AVFAudio
import Foundation
@preconcurrency import SFBAudioEngine
import StreamingInput
import Testing
import os

@testable import AudioCore

/// A pretend Icecast server at http://radio.test: /stream.mp3 and /stream.aac
/// send their file with a song title every 8 KB of audio (ICY metadata), in
/// chunks like a network; /station.pls points at /stream.mp3.
final class FakeRadio: URLProtocol, @unchecked Sendable {
    static let title = "Test Artist - Test Söng"
    nonisolated(unsafe) static var files: [String: (data: Data, type: String)] = [:]
    static let connections = OSAllocatedUnfairLock(initialState: 0)
    static let metaInterval = 8192
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeRadio.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "radio.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        if url.path == "/station.pls" {
            let body = Data("[playlist]\nNumberOfEntries=1\nFile1=http://radio.test/stream.mp3\nTitle1=Test\n".utf8)
            respond(url, type: "audio/x-scpls", headers: [:])
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard let file = Self.files[url.path] else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let icy = request.value(forHTTPHeaderField: "Icy-MetaData") == "1"
        respond(url, type: file.type, headers: icy ? ["icy-metaint": String(Self.metaInterval), "icy-name": "Test FM"] : [:])
        Self.connections.withLock { $0 += 1 }
        let body = icy ? Self.interleave(file.data) : file.data
        Thread.detachNewThread { [self] in
            var offset = 0
            while offset < body.count, !stopped.withLock({ $0 }) {
                let end = min(offset + 16 * 1024, body.count)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
                Thread.sleep(forTimeInterval: 0.01)
            }
            if !stopped.withLock({ $0 }) { client?.urlProtocolDidFinishLoading(self) }
            Self.connections.withLock { $0 -= 1 }
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    private func respond(_ url: URL, type: String, headers: [String: String]) {
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers.merging(["Content-Type": type]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    /// Audio with a metadata block after every `metaInterval` bytes (a zero-length one after the first).
    static func interleave(_ audio: Data) -> Data {
        var out = Data()
        var offset = 0, blocks = 0
        while offset < audio.count {
            let end = min(offset + metaInterval, audio.count)
            out.append(audio.subdata(in: offset..<end))
            offset = end
            var meta = Data(blocks == 0 ? [] : Array("StreamTitle='\(title)';StreamUrl='';".utf8))
            meta.append(contentsOf: [UInt8](repeating: 0, count: (16 - meta.count % 16) % 16))
            out.append(UInt8(meta.count / 16))
            out.append(meta)
            blocks += 1
        }
        return out
    }
}

@Suite struct LiveStreamParsingTests {
    @Test func streamTitlesFromMetadata() {
        #expect(LiveConnection.streamTitle(in: Data("StreamTitle='A - B';StreamUrl='x';".utf8)) == "A - B")
        #expect(LiveConnection.streamTitle(in: Data("StreamTitle='';".utf8)) == nil)
        #expect(LiveConnection.streamTitle(in: Data([0x53, 0x74]) + Data(count: 14)) == nil)
        let latin1 = "StreamTitle='Motörhead - Ace';".data(using: .isoLatin1)!
        #expect(LiveConnection.streamTitle(in: latin1) == "Motörhead - Ace")
    }

    /// A paused station keeps sending: only the latest few MB are kept.
    @Test func unreadAudioIsCapped() throws {
        let source = LiveInputSource(url: URL(string: "http://radio.test/stream.mp3")!)
        for i in 0..<20 { source.append(Data(repeating: UInt8(i), count: 256 * 1024)) }
        #expect(source.bufferedBytes == 4 * 1024 * 1024)
        try source.open()
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = try source.read(&bytes, length: 4)
        #expect(bytes == [4, 4, 4, 4])  // the first 4 chunks went
    }

    @Test func stationPlaylistsLeadToTheirStream() {
        #expect(LiveStream.firstStream(inPlaylist: "[playlist]\nFile1=http://a.test:8000/live\n")?.absoluteString == "http://a.test:8000/live")
        #expect(LiveStream.firstStream(inPlaylist: "#EXTM3U\n#EXTINF:-1,Radio\nhttps://b.test/stream\n")?.absoluteString == "https://b.test/stream")
        #expect(LiveStream.firstStream(inPlaylist: "nothing here") == nil)
    }

    @Test func decodersForServerTypes() {
        #expect(LiveStream.decoderType(for: "audio/mpeg", path: "/live") == "audio/mpeg")
        #expect(LiveStream.decoderType(for: "audio/aacp", path: "/live") == "audio/aac")
        #expect(LiveStream.decoderType(for: nil, path: "/radio.aac") == "audio/aac")
        #expect(LiveStream.decoderType(for: "application/vnd.apple.mpegurl", path: "/x.m3u8") == nil)
    }
}

extension StreamingTests {
    @Suite @MainActor struct LivePlaybackTests {
        init() throws {
            let mp3 = try #require(Bundle.module.url(forResource: "tone-20s", withExtension: "mp3", subdirectory: "Fixtures"))
            FakeRadio.files["/stream.mp3"] = (try Data(contentsOf: mp3), "audio/mpeg")
        }

        @Test func playsAStationFromItsPlaylistWithSongTitles() async throws {
            let titles = OSAllocatedUnfairLock(initialState: [String]())
            let station = URL(string: "http://radio.test/station.pls")!
            let stream = try await LiveStream.open(
                station, session: FakeRadio.configuration, onTitle: { title in titles.withLock { $0.append(title) } })
            let engine = AudioEngine()
            engine.volume = 0
            try engine.play(.live(stream))
            for _ in 0..<60 where (engine.currentTime ?? 0) < 1 {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect((engine.currentTime ?? 0) >= 1)
            #expect(engine.nowPlayingURL == station)
            #expect(!engine.canSeek)
            #expect(titles.withLock { $0 } == [FakeRadio.title])  // once, however often it is repeated
            engine.stop()
            for _ in 0..<40 where FakeRadio.connections.withLock({ $0 }) > 0 {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(FakeRadio.connections.withLock { $0 } == 0)  // stopping hangs up
        }

        @Test func playsAnAACStation() async throws {
            let aac = try encodedTone("aac")
            defer { try? FileManager.default.removeItem(at: aac) }
            FakeRadio.files["/stream.aac"] = (try Data(contentsOf: aac), "audio/aacp")
            let stream = try await LiveStream.open(URL(string: "http://radio.test/stream.aac")!, session: FakeRadio.configuration, onTitle: { _ in })
            let engine = AudioEngine()
            engine.volume = 0
            try engine.play(.live(stream))
            for _ in 0..<60 where (engine.currentTime ?? 0) < 1 {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect((engine.currentTime ?? 0) >= 1)
            engine.stop()
        }
    }
}
