import Foundation
import StreamingInput

/// Downloaded tracks, kept as plain files and evicted least recently used
/// first once the cache grows past its limit. A file's modification date is
/// its last use, so no separate index is needed.
public actor AudioCache {
    public let directory: URL
    public var limit: Int64
    /// Downloads in progress, shared by playback and prefetching.
    private var streams: [String: CacheStream] = [:]

    public init(directory: URL, limit: Int64) {
        self.directory = directory
        self.limit = limit
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        let prefix = Self.fileName(key) + "."
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.first { $0.hasPrefix(prefix) && !$0.hasSuffix(".part") }.map { directory.appendingPathComponent($0) }
    }

    /// Downloads `url` into the cache unless it is already there.
    public func fetch(_ url: URL, key: String, fileExtension: String) async throws -> URL {
        if let cached = file(for: key) { return cached }
        let stream = stream(url, key: key, fileExtension: fileExtension)
        try await stream.completion()
        return stream.url
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
        trim()
    }

    /// Bytes used.
    public func usage() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

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
