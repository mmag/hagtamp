import CryptoKit
import Foundation
import PlayerCore
import Testing

@testable import NavidromeKit

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct NavidromeParsingTests {
    let client = NavidromeClient(
        server: NavidromeServer(url: URL(string: "http://music.local:4533/")!, username: "admin"), password: "secret")

    @Test func tokenAuthenticationParameters() throws {
        let url = client.url("getAlbum", ["id": "42"])
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.path == "/rest/getAlbum")
        #expect(query["u"] == "admin" && query["id"] == "42" && query["f"] == "json" && query["v"] == "1.16.1")
        #expect(query["p"] == nil)  // the password never goes on the wire
        let salt = try #require(query["s"])
        let token = Insecure.MD5.hash(data: Data(("secret" + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(query["t"] == token)
    }

    @Test func savedTokensAuthenticateWithoutThePassword() throws {
        let saved = NavidromeCredentials.token(for: "secret")
        guard case .token(let token, let salt) = saved else { throw NavidromeError(code: -1, message: "no token") }
        #expect(token == NavidromeCredentials.md5("secret" + salt))
        let client = NavidromeClient(server: self.client.server, credentials: saved)
        let items = try #require(URLComponents(url: client.url("ping"), resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "t", value: token)) && items.contains(URLQueryItem(name: "s", value: salt)))
        // Credentials survive being written down.
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(NavidromeCredentials.self, from: data) == saved)
    }

    @Test func serverErrorsBecomeNavidromeErrors() throws {
        #expect(throws: NavidromeError(code: 40, message: "Wrong username or password")) {
            _ = try NavidromeClient.body(of: try fixture("wrongPassword"))
        }
    }

    @Test func albumWithSongsDecodes() throws {
        let body = try NavidromeClient.body(of: try fixture("getAlbum"))
        let data = try JSONSerialization.data(withJSONObject: body["album"]!)
        let album = try JSONDecoder().decode(NavidromeAlbum.self, from: data)
        #expect(album.name == "Alpha Tones Vol. 1")
        #expect(album.song?.count == 3)
        let song = try #require(album.song?.first)
        #expect(song.title == "Tone 1" && song.track == 1 && song.duration == 25)
        let info = NavidromeTrack.info(for: song)
        #expect(info.displayName == "Alpha Tones - Tone 1")
        #expect(NavidromeTrack.songID(from: info.url) == song.id)
        #expect(info.url.scheme == "hagtamp-nd")
    }

    @Test func trackURLsSurvivePlaylistFiles() {
        let url = NavidromeTrack.url(songID: "30PGUBIdTH9naXE2q3Kiwf")
        let saved = PlaylistFile.data(for: [TrackInfo(url: url, title: "T", artist: "A", duration: 25)], format: .m3u8, base: URL(fileURLWithPath: "/tmp"))
        let back = PlaylistFile.parse(saved, base: URL(fileURLWithPath: "/tmp"))
        #expect(back.first?.url == url)
    }
}

@Suite struct AudioCacheTests {
    @Test func evictsLeastRecentlyUsed() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = AudioCache(directory: folder, limit: 1_000_000)
        for (i, key) in ["a", "b", "c"].enumerated() {
            let source = folder.appendingPathComponent("src-\(key)")
            try Data(repeating: 1, count: 1000).write(to: source)
            _ = try await cache.fetch(source, key: key, fileExtension: "mp3")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: Double(i - 10))],
                ofItemAtPath: folder.appendingPathComponent("\(key).mp3").path)
            try? FileManager.default.removeItem(at: source)
        }
        // Touch "a" so "b" is the least recently used, then shrink the cache.
        #expect(await cache.file(for: "a") != nil)
        await cache.setLimit(2500)
        #expect(await cache.usage() <= 2500)
        #expect(cache.peek("a") != nil)
        #expect(cache.peek("b") == nil)
        #expect(cache.peek("c") != nil)
    }

    @Test func streamsAreSharedAndBecomeCacheEntries() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = AudioCache(directory: folder, limit: 10_000_000)
        let source = folder.appendingPathComponent("src")
        try Data(repeating: 7, count: 300_000).write(to: source)

        let first = await cache.stream(source, key: "song", fileExtension: "flac")
        let second = await cache.stream(source, key: "song", fileExtension: "flac")
        #expect(first.state === second.state)  // one download for playback and prefetch
        #expect(cache.peek("song") == nil)  // not an entry while it downloads
        try await first.completion()
        #expect(first.state.available == 300_000)
        #expect(cache.peek("song") == first.url)
        #expect(!FileManager.default.fileExists(atPath: first.partialFile.path))
        #expect(try Data(contentsOf: first.url) == Data(repeating: 7, count: 300_000))
    }

    @Test func musicKeptOfflineLivesApartFromTheCache() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cacheFolder = folder.appendingPathComponent("Caches"), offlineFolder = folder.appendingPathComponent("Offline")
        let cache = AudioCache(directory: cacheFolder, offlineDirectory: offlineFolder, limit: 10_000)
        await cache.keepOffline(keyPrefixes: ["srv-kept-"])
        for key in ["srv-kept-mp3_128", "srv-other-mp3_128"] {
            let source = folder.appendingPathComponent("src-\(key)")
            try Data(repeating: 1, count: 8000).write(to: source)
            _ = try await cache.fetch(source, key: key, fileExtension: "mp3")
        }
        // The kept song went to the offline folder as it finished; the cache holds the other.
        #expect(cache.peek(prefix: "srv-kept-")?.deletingLastPathComponent().lastPathComponent == "Offline")
        let cachedBytes = await cache.usage()
        #expect(cachedBytes == 8000 && cache.peek("srv-other-mp3_128") != nil)
        await cache.setLimit(0)  // evicts everything evictable
        await cache.clear()
        #expect(cache.peek("srv-other-mp3_128") == nil)
        let offlineBytes = await cache.offlineUsage()
        #expect(cache.peek(prefix: "srv-kept-") != nil && offlineBytes == 8000)
        // No longer kept: back into the cache, where it can go like anything else.
        await cache.keepOffline(keyPrefixes: [])
        #expect(cache.peek(prefix: "srv-kept-")?.deletingLastPathComponent().lastPathComponent == "Caches")
        #expect(await cache.offlineUsage() == 0)
    }

    @Test func failedStreamsLeaveNothingBehind() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = AudioCache(directory: folder, limit: 10_000_000)
        let stream = await cache.stream(folder.appendingPathComponent("missing"), key: "gone", fileExtension: "mp3")
        await #expect(throws: (any Error).self) { try await stream.completion() }
        #expect(cache.peek("gone") == nil)
        #expect(await cache.usage() == 0)
    }
}

/// Runs against scripts/navidrome_dev.sh when it is up.
@Suite(.enabled(if: NavidromeLive.available)) struct NavidromeLiveTests {
    let client = NavidromeLive.client

    @Test func browsesTheTestLibrary() async throws {
        try await client.ping()
        let artists = try await client.artists()
        #expect(artists.map(\.name).contains("Alpha Tones"))
        let alpha = try #require(artists.first { $0.name == "Alpha Tones" })
        let albums = try await client.albums(ofArtist: alpha.id)
        #expect(albums.count == 2)
        let album = try await client.album(albums[0].id)
        #expect(album.song?.count == 3)
        let search = try await client.search("Beta")
        #expect(search.artist?.first?.name == "Beta Waves")
        #expect(try await client.albumList(.newest).count == 4)
    }

    @Test func favouritesRoundTrip() async throws {
        let album = try #require(try await client.albumList(.alphabeticalByName).last)
        let song = try #require(try await client.album(album.id).song?.first)
        try await client.setStarred(true, .album(album.id))
        try await client.setStarred(true, .song(song.id))
        let starred = try await client.starred()
        try await client.setStarred(false, .album(album.id))
        try await client.setStarred(false, .song(song.id))
        #expect(starred.album?.contains { $0.id == album.id } == true)
        #expect(starred.song?.contains { $0.id == song.id } == true)
        let after = try await client.starred()
        #expect(after.album?.contains { $0.id == album.id } != true)
        #expect(after.song?.contains { $0.id == song.id } != true)
    }

    @Test func radioStationsRoundTrip() async throws {
        let name = "Test Radio \(UUID().uuidString.prefix(6))"
        try await client.createRadioStation(name: name, streamURL: URL(string: "http://127.0.0.1:9/stream.mp3")!)
        let station = try #require(try await client.radioStations().first { $0.name == name })
        #expect(station.streamUrl == "http://127.0.0.1:9/stream.mp3")
        try await client.deleteRadioStation(id: station.id)
        #expect(try await client.radioStations().contains { $0.name == name } == false)
    }

    @Test func aSavedTokenWorksAgainstTheServer() async throws {
        let client = NavidromeClient(server: NavidromeLive.server, credentials: .token(for: "admin"))
        try await client.ping()
    }

    @Test func wrongPasswordIsReported() async {
        let bad = NavidromeClient(server: NavidromeLive.server, password: "nope")
        await #expect(throws: NavidromeError.self) { try await bad.ping() }
    }

    @Test func downloadsIntoTheCacheWithTranscoding() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let album = try await client.albumList(.alphabeticalByName).first!
        let song = try #require(try await client.album(album.id).song?.first)
        let cache = AudioCache(directory: folder, limit: 100_000_000)
        let url = client.streamURL(songID: song.id, format: "mp3", maxBitRate: 128)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "estimateContentLength", value: "true")))
        let stream = await cache.stream(url, key: "\(song.id)-mp3", fileExtension: "mp3")
        try await stream.completion()
        #expect(stream.state.expectedLength > 0)  // announced up front, so decoders know the size
        let file = stream.url
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        #expect(size > 100_000)
        #expect(await cache.file(for: "\(song.id)-mp3") == file)
    }

    @Test func browsingFallsBackToCachedResponsesOffline() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-responses-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let online = NavidromeClient(server: NavidromeLive.server, password: "admin", responseCache: folder)
        let artists = try await online.artists()
        // The same server with the network down: the cached response answers.
        let offline = NavidromeClient(server: NavidromeLive.server, password: "admin", session: NavidromeLive.failingSession, responseCache: folder)
        #expect(try await offline.artists() == artists)
        // Nothing cached for this call: the network error comes through.
        await #expect(throws: URLError.self) { try await offline.playlists() }
    }
}

enum NavidromeLive {
    static let server = NavidromeServer(url: URL(string: "http://localhost:4533/")!, username: "admin")
    static let client = NavidromeClient(server: server, password: "admin")

    static var available: Bool {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        var request = URLRequest(url: URL(string: "http://localhost:4533/ping")!)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return ok
    }

    /// A session whose requests all fail as if the network were down.
    static var failingSession: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class OfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
