import Foundation
import StreamingInput

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
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
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

    private func streamFinished(_ key: String) {
        streams[key] = nil
        settleOffline()
        trim()
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

    /// Empties the cache; music kept offline stays.
    public func clear() {
        for entry in entries() { try? FileManager.default.removeItem(at: entry.url) }
    }

    /// Deletes least recently used files until the cache fits its limit.
    /// Downloads in progress are left alone; abandoned ones are dropped after a day.
    public func trim() {
        let active = Set(streams.values.map(\.partialFile.lastPathComponent))
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
        while total > limit, let oldest = files.first {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            files.removeFirst()
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

    private init(stream: CacheStream, completion: @escaping @Sendable () -> Void) {
        self.stream = stream
        self.completion = completion
    }

    static func start(_ url: URL, into stream: CacheStream, configuration: URLSessionConfiguration, completion: @escaping @Sendable () -> Void) {
        let download = StreamDownload(stream: stream, completion: completion)
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
        if response.expectedContentLength > 0 { stream.state.setExpectedLength(Int(response.expectedContentLength)) }
        FileManager.default.createFile(atPath: stream.partialFile.path, contents: nil)
        handle = try? FileHandle(forWritingTo: stream.partialFile)
        completionHandler(handle == nil ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
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
        if let error = error ?? (failed ? URLError(.cannotWriteToFile) : nil) {
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
