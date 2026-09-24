import AppKit
import AudioCore
import NavidromeKit
import PlayerCore

/// Stream format asked from the server; transcoding keeps downloads small.
enum StreamQuality: String, CaseIterable, Codable {
    case original, mp3_320, mp3_256, mp3_192, mp3_128

    var title: String {
        switch self {
        case .original: "Original"
        case .mp3_320: "MP3 320 kbps"
        case .mp3_256: "MP3 256 kbps"
        case .mp3_192: "MP3 192 kbps"
        case .mp3_128: "MP3 128 kbps"
        }
    }

    var maxBitRate: Int? {
        switch self {
        case .original: nil
        case .mp3_320: 320
        case .mp3_256: 256
        case .mp3_192: 192
        case .mp3_128: 128
        }
    }
}

/// Navidrome in the app: settings, the client, the audio cache, covers and
/// scrobbling. Also turns playlist entries that are Navidrome songs into
/// something the player can start: a cached file, or a download that plays
/// while it arrives and stays in the cache.
@MainActor
final class NavidromeService: RemoteTrackResolver {
    private enum Keys {
        static let url = "navidrome.url"
        static let username = "navidrome.username"
        static let quality = "navidrome.quality"
        static let cacheLimit = "navidrome.cacheLimitMB"
    }

    /// Called when settings change (the library reloads).
    var onChange: (() -> Void)?

    private(set) var server: NavidromeServer?
    private(set) var client: NavidromeClient?
    let audioCache: AudioCache
    private let coverFolder = Storage.supportDirectory.appendingPathComponent("Cache/Covers", isDirectory: true)

    var quality: StreamQuality {
        didSet { Storage.defaults.set(quality.rawValue, forKey: Keys.quality) }
    }

    var cacheLimitMB: Int {
        didSet {
            Storage.defaults.set(cacheLimitMB, forKey: Keys.cacheLimit)
            let bytes = Int64(cacheLimitMB) * 1_000_000
            Task { await audioCache.setLimit(bytes) }
        }
    }

    init() {
        let defaults = Storage.defaults
        quality = StreamQuality(rawValue: defaults.string(forKey: Keys.quality) ?? "") ?? .original
        let limit = defaults.integer(forKey: Keys.cacheLimit)
        cacheLimitMB = limit > 0 ? limit : 2000
        audioCache = AudioCache(
            directory: Storage.supportDirectory.appendingPathComponent("Cache/Audio", isDirectory: true),
            limit: Int64(limit > 0 ? limit : 2000) * 1_000_000)
        try? FileManager.default.createDirectory(at: coverFolder, withIntermediateDirectories: true)
        if let url = defaults.url(forKey: Keys.url), let username = defaults.string(forKey: Keys.username) {
            let server = NavidromeServer(url: url, username: username)
            connect(server, credentials: CredentialsStore.credentials(for: Self.account(server)) ?? Self.moveFromKeychain(server))
        }
    }

    var isConfigured: Bool { client != nil }

    /// Saved credentials for this server and user, if they are the configured ones.
    func savedCredentials(url: URL, username: String) -> NavidromeCredentials? {
        guard server == NavidromeServer(url: url, username: username) else { return nil }
        return CredentialsStore.credentials(for: Self.account(NavidromeServer(url: url, username: username)))
    }

    /// Saves the settings and reconnects; a password is kept as a token only.
    func configure(url: URL, username: String, password: String) {
        configure(url: url, username: username, credentials: .token(for: password))
    }

    func configure(url: URL, username: String, credentials: NavidromeCredentials) {
        let server = NavidromeServer(url: url, username: username)
        Storage.defaults.set(url, forKey: Keys.url)
        Storage.defaults.set(username, forKey: Keys.username)
        CredentialsStore.set(credentials, for: Self.account(server))
        connect(server, credentials: credentials)
        onChange?()
    }

    private func connect(_ server: NavidromeServer, credentials: NavidromeCredentials?) {
        self.server = server
        client = credentials.map {
            NavidromeClient(
                server: server, credentials: $0,
                responseCache: Storage.supportDirectory.appendingPathComponent("Cache/Responses", isDirectory: true))
        }
    }

    private static func account(_ server: NavidromeServer) -> String {
        "\(server.username)@\(server.url.absoluteString)"
    }

    /// Earlier versions kept the password in the Keychain: it becomes a
    /// saved token (one last Keychain prompt) and leaves the Keychain.
    private static func moveFromKeychain(_ server: NavidromeServer) -> NavidromeCredentials? {
        guard !Storage.isSelfTest, let password = Keychain.password(for: account(server)) else { return nil }
        let credentials = NavidromeCredentials.token(for: password)
        CredentialsStore.set(credentials, for: account(server))
        Keychain.deletePassword(for: account(server))
        return credentials
    }

    /// Checks credentials without saving them.
    static func test(url: URL, username: String, credentials: NavidromeCredentials) async throws {
        try await NavidromeClient(server: NavidromeServer(url: url, username: username), credentials: credentials).ping()
    }

    static func test(url: URL, username: String, password: String) async throws {
        try await test(url: url, username: username, credentials: .password(password))
    }

    // MARK: - Playing songs (RemoteTrackResolver)

    func handles(_ url: URL) -> Bool { NavidromeTrack.songID(from: url) != nil }

    private func cacheKey(_ songID: String) -> String? {
        server.map { "\($0.key)-\(songID)-\(quality.rawValue)" }
    }

    func cachedFile(for url: URL) -> URL? {
        guard let id = NavidromeTrack.songID(from: url), let key = cacheKey(id) else { return nil }
        return audioCache.peek(key)
    }

    /// Bytes a stream needs before it starts: the headers and a few seconds of audio.
    private static let prebuffer = 256 * 1024

    func prepare(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> PlayableSource {
        guard let id = NavidromeTrack.songID(from: url), let client, let key = cacheKey(id) else {
            throw NavidromeError(code: -1, message: "Navidrome is not set up (Preferences > Navidrome)")
        }
        if let cached = await audioCache.file(for: key) { return .file(cached) }
        let source: URL
        let fileExtension: String
        if let bitRate = quality.maxBitRate {
            source = client.streamURL(songID: id, format: "mp3", maxBitRate: bitRate)
            fileExtension = "mp3"
        } else {
            source = client.streamURL(songID: id)
            // The extension picks the decoder.
            fileExtension = (try? await client.song(id).suffix)?.lowercased() ?? "mp3"
        }
        let stream = await audioCache.stream(source, key: key, fileExtension: fileExtension)
        let state = stream.state
        let streamable = StreamingTrack.canStream(fileExtension: fileExtension)
        while !state.finished {
            let expected = state.expectedLength
            let needed = streamable ? (expected > 0 ? min(Self.prebuffer, expected) : Self.prebuffer) : expected
            if streamable, state.available >= needed { break }
            if needed > 0 { progress(min(1, Double(state.available) / Double(needed))) }
            try await Task.sleep(for: .milliseconds(50))
        }
        if state.finished {
            if let error = state.error { throw error }
            return .file(stream.url)
        }
        return .stream(try StreamingTrack(url: stream.url, partialFile: stream.partialFile, state: state))
    }

    // MARK: - Covers

    /// The cover of a song (via its album), cached on disk.
    func cover(for url: URL) async -> NSImage? {
        guard let id = NavidromeTrack.songID(from: url), let client, let server else { return nil }
        let file = coverFolder.appendingPathComponent("\(AudioCacheKey.safe(server.key))-\(id).img")
        if let data = try? Data(contentsOf: file) { return NSImage(data: data) }
        guard let (data, response) = try? await URLSession.shared.data(from: client.coverArtURL(id: id, size: 600)),
            (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data)
        else { return nil }
        try? data.write(to: file)
        return image
    }

    // MARK: - Scrobbling

    private var scrobbled: (songID: String, submitted: Bool)?

    /// Reports "now playing" when a song starts and a play once half of it
    /// (or four minutes) has been heard, like Last.fm-style scrobbling.
    func updateScrobbling(url: URL?, playing: Bool, elapsed: Double, duration: Double?) {
        guard let client, playing, let url, let id = NavidromeTrack.songID(from: url) else { return }
        if scrobbled?.songID != id {
            scrobbled = (id, false)
            Task { try? await client.scrobble(id, submission: false) }
        }
        let threshold = min(240, (duration ?? 480) / 2)
        if scrobbled?.submitted == false, elapsed >= threshold {
            scrobbled = (id, true)
            Task { try? await client.scrobble(id, submission: true) }
        }
    }
}

enum AudioCacheKey {
    static func safe(_ key: String) -> String {
        key.map { $0.isLetter || $0.isNumber || "-_".contains($0) ? String($0) : "_" }.joined()
    }
}
