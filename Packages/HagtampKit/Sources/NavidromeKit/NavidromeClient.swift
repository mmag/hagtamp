import CryptoKit
import Foundation
import PlayerCore

/// Connection settings; the password lives in the Keychain, not here.
public struct NavidromeServer: Codable, Equatable, Sendable {
    public var url: URL
    public var username: String

    public init(url: URL, username: String) {
        self.url = url
        self.username = username
    }

    /// Stable key for caches and track URLs: host, port and user.
    public var key: String {
        let host = url.host ?? "server"
        let port = url.port.map { "-\($0)" } ?? ""
        return "\(username)@\(host)\(port)".replacingOccurrences(of: "/", with: "_")
    }
}

/// How requests authenticate: Subsonic's token scheme, md5(password + salt).
///
/// With the password a new salt goes with every request. A saved token and
/// its salt work just as well without keeping the password anywhere.
public enum NavidromeCredentials: Codable, Equatable, Sendable {
    case password(String)
    case token(String, salt: String)

    /// A token and salt to store instead of the password.
    public static func token(for password: String) -> NavidromeCredentials {
        let salt = randomSalt()
        return .token(md5(password + salt), salt: salt)
    }

    func query() -> (token: String, salt: String) {
        switch self {
        case .password(let password):
            let salt = Self.randomSalt()
            return (Self.md5(password + salt), salt)
        case .token(let token, let salt):
            return (token, salt)
        }
    }

    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func randomSalt() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<12).map { _ in alphabet.randomElement()! })
    }
}

/// Client for Navidrome's Subsonic API.
///
/// Browsing responses are cached on disk and served from the cache when the
/// server can't be reached, so the library stays browsable offline.
public final class NavidromeClient: Sendable {
    public static let apiVersion = "1.16.1"
    public static let clientName = "hagtamp"

    public let server: NavidromeServer
    private let credentials: NavidromeCredentials
    private let session: URLSession
    private let responseCache: URL?

    /// Request URLs carry the login (a token and its salt), so they stay out
    /// of the system's HTTP cache; browsing has a cache of its own.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    public init(server: NavidromeServer, credentials: NavidromeCredentials, session: URLSession = NavidromeClient.session, responseCache: URL? = nil) {
        self.server = server
        self.credentials = credentials
        self.session = session
        self.responseCache = responseCache
        if let responseCache {
            try? FileManager.default.createDirectory(at: responseCache, withIntermediateDirectories: true)
        }
    }

    public convenience init(server: NavidromeServer, password: String, session: URLSession = NavidromeClient.session, responseCache: URL? = nil) {
        self.init(server: server, credentials: .password(password), session: session, responseCache: responseCache)
    }

    // MARK: - Browsing

    public func ping() async throws {
        _ = try await call("ping", cacheable: false)
    }

    /// All artists (the server's index flattened, in its order).
    public func artists() async throws -> [NavidromeArtist] {
        struct Index: Decodable { var artist: [NavidromeArtist]? }
        struct Artists: Decodable { var index: [Index]? }
        let result: Artists = try await payload("getArtists", key: "artists")
        return (result.index ?? []).flatMap { $0.artist ?? [] }
    }

    public func albums(ofArtist id: String) async throws -> [NavidromeAlbum] {
        struct Artist: Decodable { var album: [NavidromeAlbum]? }
        let result: Artist = try await payload("getArtist", key: "artist", ["id": id])
        return result.album ?? []
    }

    /// An album with its songs.
    public func album(_ id: String) async throws -> NavidromeAlbum {
        try await payload("getAlbum", key: "album", ["id": id])
    }

    public enum AlbumListType: String, Sendable {
        case newest, recent, frequent, random, alphabeticalByName, alphabeticalByArtist, starred
    }

    public func albumList(_ type: AlbumListType, size: Int = 100, offset: Int = 0) async throws -> [NavidromeAlbum] {
        struct List: Decodable { var album: [NavidromeAlbum]? }
        let result: List = try await payload(
            "getAlbumList2", key: "albumList2", ["type": type.rawValue, "size": String(size), "offset": String(offset)])
        return result.album ?? []
    }

    public func search(_ query: String, artists: Int = 20, albums: Int = 50, songs: Int = 200) async throws -> NavidromeSearchResult {
        try await payload(
            "search3", key: "searchResult3",
            ["query": query, "artistCount": String(artists), "albumCount": String(albums), "songCount": String(songs)])
    }

    public func playlists() async throws -> [NavidromePlaylist] {
        struct Playlists: Decodable { var playlist: [NavidromePlaylist]? }
        let result: Playlists = try await payload("getPlaylists", key: "playlists")
        return result.playlist ?? []
    }

    /// A playlist with its songs.
    public func playlist(_ id: String) async throws -> NavidromePlaylist {
        try await payload("getPlaylist", key: "playlist", ["id": id])
    }

    public func song(_ id: String) async throws -> NavidromeSong {
        try await payload("getSong", key: "song", ["id": id])
    }

    /// The user's favourites (starred artists, albums and songs).
    public func starred() async throws -> NavidromeSearchResult {
        try await payload("getStarred2", key: "starred2")
    }

    public enum StarTarget: Sendable {
        case song(String), album(String), artist(String)
    }

    /// Adds to or removes from the favourites.
    public func setStarred(_ starred: Bool, _ target: StarTarget) async throws {
        let params: [String: String] =
            switch target {
            case .song(let id): ["id": id]
            case .album(let id): ["albumId": id]
            case .artist(let id): ["artistId": id]
            }
        _ = try await call(starred ? "star" : "unstar", params, cacheable: false)
    }

    /// A song's lyrics: synced when the server has them (OpenSubsonic's
    /// getLyricsBySongId, which lyrics plugins answer too), else plain text
    /// from the older getLyrics (by artist and title). Cached for offline use.
    public func lyrics(songID: String, artist: String?, title: String?) async throws -> Lyrics? {
        if let body = try? await call("getLyricsBySongId", ["id": songID], cacheable: true),
            let lyrics = Self.structuredLyrics(in: body)
        {
            return lyrics
        }
        guard let artist, let title else { return nil }
        let body = try await call("getLyrics", ["artist": artist, "title": title], cacheable: true)
        return ((body["lyrics"] as? [String: Any])?["value"] as? String).flatMap(Lyrics.parse)
    }

    /// The best of `lyricsList.structuredLyrics`: synced over plain.
    static func structuredLyrics(in body: [String: Any]) -> Lyrics? {
        guard let list = (body["lyricsList"] as? [String: Any])?["structuredLyrics"] as? [[String: Any]] else { return nil }
        let best = list.first { $0["synced"] as? Bool == true } ?? list.first
        guard let best, let lines = best["line"] as? [[String: Any]], !lines.isEmpty else { return nil }
        let synced = best["synced"] as? Bool == true
        // Like LRC's [offset:], a positive offset brings the words earlier.
        let offset = Double(best["offset"] as? Int ?? 0) / 1000
        return Lyrics(lines: lines.map { line in
            let start = (line["start"] as? Int).map { max(0, Double($0) / 1000 - offset) }
            return Lyrics.Line(start: synced ? start : nil, text: line["value"] as? String ?? "")
        })
    }

    /// Rescans the music folders (admins only); for tests and scripts.
    public func startScan() async throws {
        _ = try await call("startScan", ["fullScan": "true"], cacheable: false)
    }

    public func isScanning() async throws -> Bool {
        let body = try await call("getScanStatus", cacheable: false)
        return (body["scanStatus"] as? [String: Any])?["scanning"] as? Bool ?? false
    }

    /// Internet radio stations configured on the server.
    public func radioStations() async throws -> [NavidromeRadioStation] {
        struct Stations: Decodable { var internetRadioStation: [NavidromeRadioStation]? }
        let result: Stations = try await payload("getInternetRadioStations", key: "internetRadioStations")
        return result.internetRadioStation ?? []
    }

    /// Adds a station (admins only); for tests and scripts.
    public func createRadioStation(name: String, streamURL: URL, homePage: URL? = nil) async throws {
        var params = ["name": name, "streamUrl": streamURL.absoluteString]
        if let homePage { params["homepageUrl"] = homePage.absoluteString }
        _ = try await call("createInternetRadioStation", params, cacheable: false)
    }

    public func deleteRadioStation(id: String) async throws {
        _ = try await call("deleteInternetRadioStation", ["id": id], cacheable: false)
    }

    /// Tells the server what is playing (`submission` false) or was played.
    public func scrobble(_ songID: String, submission: Bool) async throws {
        _ = try await call("scrobble", ["id": songID, "submission": submission ? "true" : "false"], cacheable: false)
    }

    // MARK: - Media URLs

    /// Stream URL; `format`/`maxBitRate` ask the server to transcode (nil = original file).
    /// No estimated length is asked for: Navidrome's estimate runs a few percent
    /// over, and a response shorter than announced ends as a failed download.
    public func streamURL(songID: String, format: String? = nil, maxBitRate: Int? = nil) -> URL {
        var params = ["id": songID]
        if let format { params["format"] = format }
        if let maxBitRate { params["maxBitRate"] = String(maxBitRate) }
        return url("stream", params)
    }

    public func coverArtURL(id: String, size: Int? = nil) -> URL {
        var params = ["id": id]
        if let size { params["size"] = String(size) }
        return url("getCoverArt", params)
    }

    // MARK: - Requests

    func url(_ endpoint: String, _ params: [String: String] = [:]) -> URL {
        let (token, salt) = credentials.query()
        var components = URLComponents(url: server.url.appendingPathComponent("rest/\(endpoint)"), resolvingAgainstBaseURL: false)!
        let auth = [
            "u": server.username, "t": token, "s": salt, "v": Self.apiVersion, "c": Self.clientName, "f": "json",
        ]
        components.queryItems = auth.merging(params) { _, new in new }.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private func payload<T: Decodable>(_ endpoint: String, key: String, _ params: [String: String] = [:]) async throws -> T {
        let body = try await call(endpoint, params, cacheable: true)
        guard let value = body[key] else { throw NavidromeError(code: -1, message: "Missing \(key) in \(endpoint) response") }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The `subsonic-response` object of a call; cacheable calls fall back to
    /// the last good response when the server can't be reached.
    private func call(_ endpoint: String, _ params: [String: String] = [:], cacheable: Bool) async throws -> [String: Any] {
        let cacheFile = cacheable ? cacheURL(endpoint, params) : nil
        let data: Data
        do {
            let (fetched, response) = try await session.data(from: url(endpoint, params))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NavidromeError(code: -http.statusCode, message: "HTTP \(http.statusCode)")
            }
            data = fetched
        } catch let error as URLError {
            if let cacheFile, let cached = try? Data(contentsOf: cacheFile) {
                return try Self.body(of: cached)
            }
            throw error
        }
        let body = try Self.body(of: data)
        if let cacheFile { try? data.write(to: cacheFile, options: .atomic) }
        return body
    }

    static func body(of data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let body = json["subsonic-response"] as? [String: Any]
        else { throw NavidromeError(code: -1, message: "Not a Subsonic response") }
        if body["status"] as? String != "ok" {
            let error = body["error"] as? [String: Any]
            throw NavidromeError(code: error?["code"] as? Int ?? -1, message: error?["message"] as? String ?? "Request failed")
        }
        return body
    }

    private func cacheURL(_ endpoint: String, _ params: [String: String]) -> URL? {
        guard let responseCache else { return nil }
        let key = ([server.key, endpoint] + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: "&")
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return responseCache.appendingPathComponent("\(name).json")
    }
}
