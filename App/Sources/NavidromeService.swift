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
    private let loudness: LoudnessService
    private let coverFolder = Storage.cacheDirectory.appendingPathComponent("Covers", isDirectory: true)

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

    init(loudness: LoudnessService) {
        self.loudness = loudness
        let defaults = Storage.defaults
        quality = StreamQuality(rawValue: defaults.string(forKey: Keys.quality) ?? "") ?? .original
        let limit = defaults.integer(forKey: Keys.cacheLimit)
        cacheLimitMB = limit > 0 ? limit : 2000
        Self.moveOldCache()
        audioCache = AudioCache(
            directory: Storage.cacheDirectory.appendingPathComponent("Audio", isDirectory: true),
            offlineDirectory: Storage.supportDirectory.appendingPathComponent("Offline", isDirectory: true),
            limit: Int64(limit > 0 ? limit : 2000) * 1_000_000)
        try? FileManager.default.createDirectory(at: coverFolder, withIntermediateDirectories: true)
        let downloaded: @Sendable (String, URL) -> Void = { [weak self] key, file in
            Task { @MainActor in self?.downloaded(key, file) }
        }
        Task { [audioCache] in
            await audioCache.removeInvalidFiles()
            await audioCache.observeDownloads(downloaded)
        }
        Self.forgetHTTPCache()
        Self.trim(coverFolder, to: 150_000_000)
        Self.trim(Self.responseFolder, to: 50_000_000)
        if let url = defaults.url(forKey: Keys.url), let username = defaults.string(forKey: Keys.username) {
            let server = NavidromeServer(url: url, username: username)
            connect(server, credentials: CredentialsStore.credentials(for: Self.account(server)) ?? Self.moveFromKeychain(server))
            protectOfflineSongs()
            syncOffline()
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
        let previous = self.server
        Storage.defaults.set(url, forKey: Keys.url)
        Storage.defaults.set(username, forKey: Keys.username)
        CredentialsStore.set(credentials, for: Self.account(server))
        connect(server, credentials: credentials)
        protectOfflineSongs()
        if let previous, previous.key != server.key { adoptOfflineMusic(of: previous) }
        onChange?()
    }

    private static var responseFolder: URL { Storage.cacheDirectory.appendingPathComponent("Responses", isDirectory: true) }

    private func connect(_ server: NavidromeServer, credentials: NavidromeCredentials?) {
        self.server = server
        client = credentials.map { NavidromeClient(server: server, credentials: $0, responseCache: Self.responseFolder) }
        starred = []
        playlists = []
        Task {
            _ = try? await starredOnServer()
            _ = try? await refreshPlaylists()
        }
        readCachedLoudness()
    }

    /// The same server at a new address (say an IP address replaced by a
    /// host name): its music kept offline and its cache carry over. It counts
    /// as the same server when an album or playlist kept offline is there too.
    private func adoptOfflineMusic(of previous: NavidromeServer) {
        let all = Self.savedPins()
        guard let server, let client, let pins = all[previous.key], let probe = pins.first, all[server.key]?.isEmpty ?? true else { return }
        Task {
            let found = (try? await (probe.kind == .album ? client.album(probe.id).song : client.playlist(probe.id).entry)) != nil
            guard found, self.server?.key == server.key else { return }
            var all = Self.savedPins()
            all[server.key] = all.removeValue(forKey: previous.key)
            try? JSONEncoder().encode(all).write(to: Self.pinsFile, options: .atomic)
            await audioCache.renameFiles(prefix: "\(previous.key)-", to: "\(server.key)-")
            protectOfflineSongs()
            onChange?()
        }
    }

    /// Earlier versions fetched through the shared URL session, whose HTTP
    /// cache (Caches/<bundle id>/Cache.db) kept request URLs, login token included.
    private static func forgetHTTPCache() {
        let key = "httpCacheForgotten"
        guard !Storage.defaults.bool(forKey: key) else { return }
        URLCache.shared.removeAllCachedResponses()
        Storage.defaults.set(true, forKey: key)
    }

    /// Deletes the least recently written files of a folder beyond `limit` bytes.
    private static func trim(_ folder: URL, to limit: Int64) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []).map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url: url, size: Int64(values?.fileSize ?? 0), date: values?.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(0) { $0 + $1.size }
        files.sort { $0.date < $1.date }
        for file in files where total > limit {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    /// Empties the audio cache and the covers (music kept offline stays).
    func clearCache() async {
        await audioCache.clear()
        for file in (try? FileManager.default.contentsOfDirectory(at: coverFolder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Earlier versions kept the whole cache in Application Support/Hagtamp/Cache;
    /// it moves to Caches (music kept offline then settles into Offline).
    private static func moveOldCache() {
        let old = Storage.supportDirectory.appendingPathComponent("Cache", isDirectory: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: old.path) else { return }
        for name in ["Audio", "Covers", "Responses"] {
            let from = old.appendingPathComponent(name), to = Storage.cacheDirectory.appendingPathComponent(name)
            try? manager.createDirectory(at: to, withIntermediateDirectories: true)
            for file in (try? manager.contentsOfDirectory(atPath: from.path)) ?? [] {
                try? manager.moveItem(at: from.appendingPathComponent(file), to: to.appendingPathComponent(file))
            }
        }
        try? manager.removeItem(at: old)
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

    /// A downloaded song about to play: marked as used, so trimming the cache
    /// leaves it be.
    func cachedFile(for url: URL) -> URL? {
        guard let file = downloadedFile(for: url) else { return nil }
        audioCache.markUsed(file)
        return file
    }

    private func downloadedFile(for url: URL) -> URL? {
        guard let id = NavidromeTrack.songID(from: url), let key = cacheKey(id), let server else { return nil }
        // A song kept offline plays in whatever quality it was downloaded.
        return audioCache.peek(key) ?? (offlineSongIDs.contains(id) ? audioCache.peek(prefix: "\(server.key)-\(id)-") : nil)
    }

    /// Where a song streams from in the chosen quality, and its file extension.
    private func streamSource(_ id: String, client: NavidromeClient) async -> (url: URL, fileExtension: String) {
        if let bitRate = quality.maxBitRate {
            return (client.streamURL(songID: id, format: "mp3", maxBitRate: bitRate), "mp3")
        }
        // The extension picks the decoder.
        return (client.streamURL(songID: id), (try? await client.song(id).suffix)?.lowercased() ?? "mp3")
    }

    /// Bytes a stream needs before it starts: the headers and a few seconds of audio.
    private static let prebuffer = 256 * 1024

    func prepare(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> PlayableSource {
        guard let id = NavidromeTrack.songID(from: url), let client, let key = cacheKey(id) else {
            throw NavidromeError(code: -1, message: "Navidrome is not set up (Preferences > Navidrome)")
        }
        if let cached = await audioCache.file(for: key) { return .file(cached) }
        if let kept = cachedFile(for: url) { return .file(kept) }
        let (source, fileExtension) = await streamSource(id, client: client)
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
            return .file(cachedFile(for: url) ?? stream.url)  // kept offline, it has moved
        }
        audioCache.markUsed(stream.url)  // the file it becomes
        return .stream(try StreamingTrack(url: stream.url, partialFile: stream.partialFile, state: state))
    }

    func info(for url: URL) async -> TrackInfo? {
        guard let id = NavidromeTrack.songID(from: url), let client, let song = try? await client.song(id) else { return nil }
        return NavidromeTrack.info(for: song)
    }

    // MARK: - Loudness

    /// A song's loudness is kept by server and song, whatever the quality.
    func loudnessKey(for url: URL) -> String? {
        guard let id = NavidromeTrack.songID(from: url), let server else { return nil }
        return "navidrome:\(server.key):\(id)"
    }

    func loudnessJob(for url: URL) -> LoudnessService.Job? {
        guard let file = downloadedFile(for: url) else { return nil }
        return loudnessJob(for: url, file: file)
    }

    private func loudnessJob(for url: URL, file: URL) -> LoudnessService.Job? {
        guard let key = loudnessKey(for: url), let server else { return nil }
        return LoudnessService.Job(key: key, file: file, albumScope: "navidrome:\(server.key)")
    }

    /// A song downloaded (played, fetched ahead or kept offline) is read in the background.
    private func downloaded(_ cacheKey: String, _ file: URL) {
        guard let server, cacheKey.hasPrefix("\(server.key)-"), let id = Self.songID(fromKeySuffix: String(cacheKey.dropFirst(server.key.count + 1))),
            let job = loudnessJob(for: NavidromeTrack.url(songID: id), file: file)
        else { return }
        loudness.readLater(job, source: "navidrome")
    }

    /// So are the songs in the cache and kept offline.
    private func readCachedLoudness() {
        guard let server else { return }
        let jobs = audioCache.files(keyPrefix: "\(server.key)-").compactMap { suffix, file in
            Self.songID(fromKeySuffix: suffix).flatMap { loudnessJob(for: NavidromeTrack.url(songID: $0), file: file) }
        }
        loudness.setBacklog(jobs, for: "navidrome")
    }

    /// The song in the rest of a cache key: "<song>-<quality>".
    private static func songID(fromKeySuffix suffix: String) -> String? {
        guard let quality = StreamQuality.allCases.first(where: { suffix.hasSuffix("-\($0.rawValue)") }) else { return nil }
        let id = String(suffix.dropLast(quality.rawValue.count + 1))
        return id.isEmpty ? nil : id
    }

    // MARK: - Keep offline

    /// An album or playlist whose songs stay in the cache.
    struct OfflinePin: Codable, Hashable {
        enum Kind: String, Codable { case album, playlist }
        var kind: Kind
        var id: String
        var name: String
        var songIDs: [String] = []
    }

    private static var pinsFile: URL { Storage.supportDirectory.appendingPathComponent("offline.json") }

    /// Pins of the configured server.
    var offlinePins: [OfflinePin] {
        get { server.flatMap { Self.savedPins()[$0.key] } ?? [] }
        set {
            guard let server else { return }
            var all = Self.savedPins()
            all[server.key] = newValue
            try? JSONEncoder().encode(all).write(to: Self.pinsFile, options: .atomic)
            protectOfflineSongs()
        }
    }

    private static func savedPins() -> [String: [OfflinePin]] {
        (try? Data(contentsOf: pinsFile)).flatMap { try? JSONDecoder().decode([String: [OfflinePin]].self, from: $0) } ?? [:]
    }

    private var offlineSongIDs: Set<String> { Set(offlinePins.flatMap(\.songIDs)) }
    /// Songs downloaded / to download while keeping music offline.
    private(set) var offlineProgress: (done: Int, total: Int)?
    /// Songs the last offline sync couldn't download (tried again at the next).
    private(set) var offlineFailures = 0
    private var offlineTask: Task<Void, Never>?

    func isKeptOffline(_ kind: OfflinePin.Kind, id: String) -> Bool {
        offlinePins.contains { $0.kind == kind && $0.id == id }
    }

    func setKeptOffline(_ kind: OfflinePin.Kind, id: String, name: String, _ keep: Bool) {
        var pins = offlinePins.filter { !($0.kind == kind && $0.id == id) }
        if keep { pins.append(OfflinePin(kind: kind, id: id, name: name)) }
        offlinePins = pins
        onChange?()
        if keep { syncOffline() }
    }

    /// Refreshes the pinned song lists (playlists change) and downloads what is missing.
    func syncOffline() {
        guard let client, server != nil, !offlinePins.isEmpty else { return }
        offlineTask?.cancel()
        offlineTask = Task { [weak self] in
            guard let self else { return }
            var refreshed: [String: [String]] = [:]
            for pin in self.offlinePins {
                let songs = try? await (pin.kind == .album ? client.album(pin.id).song : client.playlist(pin.id).entry)
                if let songs { refreshed["\(pin.kind.rawValue)/\(pin.id)"] = songs.map(\.id) }
            }
            guard !Task.isCancelled else { return }
            // Pins may have changed meanwhile: only those still there take the new lists.
            self.offlinePins = self.offlinePins.map { pin in
                var pin = pin
                if let songs = refreshed["\(pin.kind.rawValue)/\(pin.id)"] { pin.songIDs = songs }
                return pin
            }
            await self.audioCache.removeInvalidFiles()
            let missing = Array(self.offlineSongIDs.filter { self.downloadedFile(for: NavidromeTrack.url(songID: $0)) == nil })
            self.offlineProgress = missing.isEmpty ? nil : (0, missing.count)
            self.offlineFailures = 0
            self.onChange?()
            for (done, id) in missing.enumerated() {
                guard !Task.isCancelled, let key = self.cacheKey(id) else { break }
                // Unkept while this runs: skipped.
                if self.offlineSongIDs.contains(id) {
                    let (source, fileExtension) = await self.streamSource(id, client: client)
                    if (try? await self.audioCache.fetch(source, key: key, fileExtension: fileExtension)) == nil { self.offlineFailures += 1 }
                }
                self.offlineProgress = (done + 1, missing.count)
                self.onChange?()
            }
            self.offlineProgress = nil
            self.onChange?()
        }
    }

    /// Music kept offline for any server stays out of the cache's reach,
    /// not only the configured one's.
    private func protectOfflineSongs() {
        let prefixes = Set(Self.savedPins().flatMap { key, pins in pins.flatMap(\.songIDs).map { "\(key)-\($0)-" } })
        Task { await audioCache.keepOffline(keyPrefixes: prefixes) }
    }

    // MARK: - Favourites

    /// What is starred on the server: as it last listed it, with the changes made here since.
    private var starred: Set<NavidromeClient.StarTarget> = []
    /// Changes on their way to the server, one after the other.
    private var starring: Task<Void, Never>?

    func isStarred(_ target: NavidromeClient.StarTarget) -> Bool {
        starred.contains(target)
    }

    /// Marks at once, then tells the server once the earlier changes have
    /// reached it; what it doesn't take goes back as it was. The task ends
    /// when the server has it.
    @discardableResult
    func setStarred(_ targets: [NavidromeClient.StarTarget], _ star: Bool) -> Task<Void, Error> {
        guard let client else { return Task { throw NavidromeError(code: -1, message: "Navidrome is not set up.") } }
        let before = starred
        for target in targets { mark(target, star) }
        let previous = starring
        let request = Task {
            await previous?.value
            for (i, target) in targets.enumerated() {
                do {
                    try await client.setStarred(star, target)
                } catch {
                    for target in targets[i...] { self.mark(target, before.contains(target)) }
                    throw error
                }
            }
        }
        starring = Task { _ = await request.result }
        return request
    }

    /// The favourites as the server lists them, after the changes made here.
    func starredOnServer() async throws -> NavidromeSearchResult {
        guard let client else { throw NavidromeError(code: -1, message: "Navidrome is not set up.") }
        await starring?.value
        let result = try await client.starred()
        guard self.client === client else { return result }
        starred = Set(
            (result.artist ?? []).map { .artist($0.id) } + (result.album ?? []).map { .album($0.id) }
                + (result.song ?? []).map { .song($0.id) })
        return result
    }

    private func mark(_ target: NavidromeClient.StarTarget, _ star: Bool) {
        if star { starred.insert(target) } else { starred.remove(target) }
    }

    // MARK: - Playlists

    /// The server's playlists as last listed, for menus that can't wait.
    private(set) var playlists: [NavidromePlaylist] = []

    @discardableResult
    func refreshPlaylists() async throws -> [NavidromePlaylist] {
        guard let client else { throw NavidromeError(code: -1, message: "Navidrome is not set up.") }
        let result = try await client.playlists()
        if self.client === client { playlists = result }
        return result
    }

    /// The user's own playlists, smart ones aside.
    func canEdit(_ playlist: NavidromePlaylist) -> Bool {
        playlist.readonly != true && (playlist.owner == nil || playlist.owner == server?.username)
    }

    // MARK: - Lyrics

    func lyrics(for track: TrackInfo) async -> Lyrics? {
        guard let id = NavidromeTrack.songID(from: track.url), let client else { return nil }
        return try? await client.lyrics(songID: id, artist: track.artist, title: track.title)
    }

    // MARK: - Covers

    /// The cover of a song (via its album), cached on disk.
    func cover(for url: URL) async -> NSImage? {
        guard let id = NavidromeTrack.songID(from: url), let client, let server else { return nil }
        let file = coverFolder.appendingPathComponent("\(AudioCacheKey.safe(server.key))-\(id).img")
        if let data = try? Data(contentsOf: file) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)  // recently used
            return NSImage(data: data)
        }
        guard let (data, response) = try? await NavidromeClient.session.data(from: client.coverArtURL(id: id, size: 600)),
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
