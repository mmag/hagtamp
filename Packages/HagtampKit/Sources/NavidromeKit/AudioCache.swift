import Foundation
import StreamingInput
import os

/// Downloaded tracks as plain files, in two places: the cache proper,
/// whose least recently used files go once it grows past its limit (a
/// file's modification date is its last use, so no index is needed), and
/// the offline folder for music kept offline, never evicted or cleared.
public actor AudioCache {
    public nonisolated let directory: URL
    public nonisolated let offlineDirectory: URL?
    public var limit: Int64
    /// Downloads in progress, shared by playback and prefetching.
    private var streams: [String: CacheStream] = [:]
    /// File name prefixes of what is kept offline.
    private var offline: Set<String> = []
    /// Files handed to the player lately, which trimming and clearing leave be
    /// (a queued track is only opened when its turn comes).
    private nonisolated let inUse = OSAllocatedUnfairLock<[String]>(initialState: [])
    private var onDownload: (@Sendable (_ key: String, _ file: URL) -> Void)?

    public init(directory: URL, offlineDirectory: URL? = nil, limit: Int64) {
        self.directory = directory
        self.offlineDirectory = offlineDirectory
        self.limit = limit
        for folder in [directory, offlineDirectory].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    public func setLimit(_ bytes: Int64) {
        limit = bytes
        trim()
    }

    /// The cached file for `key`, marked as just used.
    public func file(for key: String) -> URL? {
        guard let url = existingFile(key) else { return nil }
        markUsed(url)
        return url
    }

    /// A file about to play: it goes last when the cache is trimmed, and
    /// trimming or clearing won't take it while it is among the latest.
    public nonisolated func markUsed(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        inUse.withLock { names in
            names.removeAll { $0 == url.lastPathComponent }
            names.append(url.lastPathComponent)
            if names.count > 4 { names.removeFirst() }
        }
    }

    /// Non-isolated check without touching the file, for synchronous callers.
    public nonisolated func peek(_ key: String) -> URL? {
        find(fileNamePrefix: Self.fileName(key) + ".")
    }

    /// Any finished file whose key starts with `keyPrefix` (e.g. one song in any quality).
    public nonisolated func peek(prefix keyPrefix: String) -> URL? {
        find(fileNamePrefix: Self.fileName(keyPrefix))
    }

    /// The offline folder first, then the cache.
    private nonisolated func find(fileNamePrefix prefix: String) -> URL? {
        for folder in [offlineDirectory, directory].compactMap({ $0 }) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            if let name = files.first(where: { $0.hasPrefix(prefix) && !$0.hasSuffix(".part") }) {
                return folder.appendingPathComponent(name)
            }
        }
        return nil
    }

    /// Keeps files whose keys start with these prefixes offline: they move to
    /// the offline folder (now and when downloaded), and files no longer
    /// kept move back into the cache.
    public func keepOffline(keyPrefixes: Set<String>) {
        offline = Set(keyPrefixes.map(Self.fileName))
        settleOffline()
    }

    private func isOffline(_ name: String) -> Bool {
        offline.contains { name.hasPrefix($0) }
    }

    private func settleOffline() {
        guard let offlineDirectory else { return }
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where !name.hasSuffix(".part") && isOffline(name) {
            try? manager.removeItem(at: offlineDirectory.appendingPathComponent(name))
            try? manager.moveItem(at: directory.appendingPathComponent(name), to: offlineDirectory.appendingPathComponent(name))
        }
        for name in (try? manager.contentsOfDirectory(atPath: offlineDirectory.path)) ?? [] where !isOffline(name) {
            let target = directory.appendingPathComponent(name)
            try? manager.removeItem(at: target)
            if (try? manager.moveItem(at: offlineDirectory.appendingPathComponent(name), to: target)) != nil {
                try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            }
        }
    }

    /// Downloads `url` into the cache unless it is already there.
    public func fetch(_ url: URL, key: String, fileExtension: String) async throws -> URL {
        if let cached = file(for: key) { return cached }
        let stream = stream(url, key: key, fileExtension: fileExtension)
        try await stream.completion()
        return peek(key) ?? stream.url  // it may have moved offline
    }

    /// A download that can be played while it runs: the running one for
    /// `key`, or a new one. Once complete the file is an ordinary cache entry.
    public func stream(_ url: URL, key: String, fileExtension: String, session configuration: URLSessionConfiguration = .default) -> CacheStream {
        if let running = streams[key] { return running }
        let name = Self.fileName(key)
        let fileExtension = Self.safeExtension(fileExtension)
        let stream = CacheStream(
            url: directory.appendingPathComponent("\(name).\(fileExtension)"),
            partialFile: directory.appendingPathComponent("\(name).\(fileExtension).part"),
            state: StreamState())
        streams[key] = stream
        StreamDownload.start(url, into: stream, configuration: configuration) { [weak self] in
            Task { await self?.streamFinished(key) }
        }
        return stream
    }

    /// Called with each download that completes, where its file ended up.
    public func observeDownloads(_ observer: @escaping @Sendable (_ key: String, _ file: URL) -> Void) {
        onDownload = observer
    }

    private func streamFinished(_ key: String) {
        let succeeded = streams.removeValue(forKey: key)?.state.error == nil
        settleOffline()
        trim()
        if succeeded, let file = peek(key) { onDownload?(key, file) }
    }

    /// The finished files whose keys start with `keyPrefix`, cached or kept
    /// offline, with the rest of their key (extension dropped).
    public nonisolated func files(keyPrefix: String) -> [(keySuffix: String, file: URL)] {
        let prefix = Self.fileName(keyPrefix)
        return [directory, offlineDirectory].compactMap { $0 }.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix(prefix) && !$0.hasSuffix(".part") }
                .map { name in
                    (String((name as NSString).deletingPathExtension.dropFirst(prefix.count)), folder.appendingPathComponent(name))
                }
        }
    }

    /// Bytes in the cache (not counting music kept offline).
    public func usage() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    /// Bytes of music kept offline.
    public func offlineUsage() -> Int64 {
        guard let offlineDirectory else { return 0 }
        let files = (try? FileManager.default.contentsOfDirectory(at: offlineDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Empties the cache; music kept offline stays, and so do downloads in
    /// progress and the files playing or queued.
    public func clear() {
        let keep = Set(streams.values.map(\.partialFile.lastPathComponent)).union(inUse.withLock { $0 })
        for entry in entries() where !keep.contains(entry.url.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    /// Earlier versions could keep a server's error message as if it were a
    /// song. Such files (small, JSON or markup) go, here and offline.
    public func removeInvalidFiles() {
        for folder in [directory, offlineDirectory].compactMap({ $0 }) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for url in files where url.pathExtension != "part" {
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 65_536,
                    let data = try? Data(contentsOf: url), Self.isErrorMessage(data)
                else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// No audio format starts with "{" or "<" (after blanks); JSON, XML and HTML
    /// do. An empty file isn't audio either.
    static func isErrorMessage(_ data: Data) -> Bool {
        guard let first = data.first(where: { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }) else { return true }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "<")
    }

    /// Moves the files of one key prefix to another (a server reached at a new address).
    public func renameFiles(prefix old: String, to new: String) {
        let from = Self.fileName(old), to = Self.fileName(new)
        guard from != to else { return }
        let manager = FileManager.default
        for folder in [directory, offlineDirectory].compactMap({ $0 }) {
            for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(from) && !name.hasSuffix(".part") {
                let target = folder.appendingPathComponent(to + name.dropFirst(from.count))
                guard !manager.fileExists(atPath: target.path) else { continue }
                try? manager.moveItem(at: folder.appendingPathComponent(name), to: target)
            }
        }
    }

    /// Deletes least recently used files until the cache fits its limit.
    /// Downloads in progress are left alone; abandoned ones are dropped after a day.
    public func trim() {
        let active = Set(streams.values.map(\.partialFile.lastPathComponent))
        let playing = Set(inUse.withLock { $0 })
        var files: [(url: URL, size: Int64, used: Date)] = []
        for entry in entries() {
            guard entry.url.pathExtension == "part" else {
                files.append(entry)
                continue
            }
            if !active.contains(entry.url.lastPathComponent), entry.used < Date(timeIntervalSinceNow: -86_400) {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
        files.sort { $0.used < $1.used }
        var total = files.reduce(0) { $0 + $1.size }
        // Files playing or queued count, but stay.
        for file in files where total > limit && !playing.contains(file.url.lastPathComponent) {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    private func existingFile(_ key: String) -> URL? { peek(key) }

    private func entries() -> [(url: URL, size: Int64, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }

    /// Keys may contain anything; file names must not.
    static func fileName(_ key: String) -> String {
        key.map { $0.isLetter || $0.isNumber || "-_".contains($0) ? String($0) : "_" }.joined()
    }

    /// Extensions come from the server: lowercase ASCII letters and digits only.
    static func safeExtension(_ ext: String) -> String {
        let clean = String(ext.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        return clean.isEmpty ? "audio" : clean
    }
}

/// A download in progress: bytes go to `partialFile`, which becomes `url` when complete.
public struct CacheStream: Sendable {
    public let url: URL
    public let partialFile: URL
    public let state: StreamState

    /// Waits for the download to complete.
    public func completion() async throws {
        while !state.finished { try await Task.sleep(for: .milliseconds(50)) }
        if let error = state.error { throw error }
    }
}

/// Writes a response body to a cache stream as it arrives.
private final class StreamDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let stream: CacheStream
    private let completion: @Sendable () -> Void
    private var handle: FileHandle?
    private var failed = false
    /// Set when the server answered with a message instead of audio.
    private var errorBody: Data?

    private init(stream: CacheStream, completion: @escaping @Sendable () -> Void) {
        self.stream = stream
        self.completion = completion
    }

    static func start(_ url: URL, into stream: CacheStream, configuration: URLSessionConfiguration, completion: @escaping @Sendable () -> Void) {
        let download = StreamDownload(stream: stream, completion: completion)
        // Stream URLs carry the login: nothing goes to the system's HTTP cache.
        let configuration = configuration.copy() as? URLSessionConfiguration ?? .default
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: queue)
        session.dataTask(with: url).resume()
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failed = true
            stream.state.finishWithError(URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        // Subsonic reports errors (a wrong password, an unknown song) with status 200
        // and a JSON or XML body; a proxy's login page is HTML. None of it is a song.
        if let type = response.mimeType?.lowercased(), type.hasPrefix("text/") || type.contains("json") || type.contains("xml") {
            errorBody = Data()
            completionHandler(.allow)
            return
        }
        if response.expectedContentLength > 0 { stream.state.setExpectedLength(Int(response.expectedContentLength)) }
        FileManager.default.createFile(atPath: stream.partialFile.path, contents: nil)
        handle = try? FileHandle(forWritingTo: stream.partialFile)
        completionHandler(handle == nil ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if errorBody != nil {
            if errorBody!.count < 65_536 { errorBody!.append(data) }
            return
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            stream.state.appendedBytes(data.count)
        } catch {
            failed = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        if let body = errorBody {
            // The server's own words when it sent a Subsonic error.
            var reason: Error = NavidromeError(code: -1, message: "The server sent a page instead of the song")
            do { _ = try NavidromeClient.body(of: body) } catch let subsonic as NavidromeError where subsonic.code != -1 { reason = subsonic } catch {}
            stream.state.finishWithError(reason)
        } else if let error = error ?? (failed ? URLError(.cannotWriteToFile) : nil) {
            try? FileManager.default.removeItem(at: stream.partialFile)
            if !stream.state.finished { stream.state.finishWithError(error) }
        } else {
            // Readers keep their open descriptor across the rename.
            try? FileManager.default.removeItem(at: stream.url)
            try? FileManager.default.moveItem(at: stream.partialFile, to: stream.url)
            stream.state.finishWithError(nil)
        }
        completion()
    }
}
