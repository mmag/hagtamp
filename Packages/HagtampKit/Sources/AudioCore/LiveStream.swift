import AudioToolbox
import Foundation
@preconcurrency import SFBAudioEngine
import StreamingInput

/// Internet radio: an endless HTTP stream (Shoutcast, Icecast) played as it
/// arrives. Song titles sent in the stream (ICY metadata) are reported as
/// they change.
public final class LiveStream: @unchecked Sendable {
    /// What the stream was opened for (the playlist entry), also the decoder's URL.
    public let url: URL
    let decoder: any PCMDecoding
    private let source: LiveInputSource
    private let connection: LiveConnection

    private init(url: URL, source: LiveInputSource, connection: LiveConnection, mimeType: String) throws {
        self.url = url
        self.source = source
        self.connection = connection
        if mimeType == "audio/aac" {
            // Core Audio's file decoder needs the whole file; this one parses as bytes come.
            decoder = AudioStreamDecoder(inputSource: source, fileType: kAudioFileAAC_ADTSType)
        } else {
            decoder = try AudioDecoder(inputSource: source, detectContentType: false, mimeTypeHint: mimeType)
        }
    }

    /// Connects to `url` (a station playlist, .pls or .m3u, leads to its first
    /// stream) and returns once `prebuffer` bytes are in, reporting progress 0...1.
    public static func open(
        _ url: URL, prebuffer: Int = 48 * 1024, session configuration: URLSessionConfiguration = .default,
        onTitle: @escaping @Sendable (String) -> Void, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> LiveStream {
        var streamURL = url
        if Self.isPlaylist(path: url.path, contentType: nil) {
            streamURL = try await resolve(playlist: url, configuration: configuration)
        }
        var source = LiveInputSource(url: url)
        var connection = LiveConnection(source: source, onTitle: onTitle)
        var response = try await start(connection, streamURL, configuration: configuration)
        // Some station links serve a playlist without saying so in the name.
        if isPlaylist(path: "", contentType: response.mimeType) {
            connection.cancel()
            streamURL = try await resolve(playlist: streamURL, configuration: configuration)
            source = LiveInputSource(url: url)
            connection = LiveConnection(source: source, onTitle: onTitle)
            response = try await start(connection, streamURL, configuration: configuration)
        }
        guard let mimeType = decoderType(for: response.mimeType, path: streamURL.path) else {
            connection.cancel()
            throw LiveStreamError("Unsupported stream type \(response.mimeType ?? "(none)")")
        }
        do {
            while source.bufferedBytes < prebuffer && !source.finished {
                try Task.checkCancellation()
                progress(Double(source.bufferedBytes) / Double(prebuffer))
                try await Task.sleep(for: .milliseconds(50))
            }
            if source.finished && source.bufferedBytes == 0 { throw LiveStreamError("The station sent nothing") }
            return try LiveStream(url: url, source: source, connection: connection, mimeType: mimeType)
        } catch {
            connection.cancel()
            throw error
        }
    }

    /// A connection that fails to start is closed (its session would keep it alive).
    private static func start(_ connection: LiveConnection, _ url: URL, configuration: URLSessionConfiguration) async throws -> URLResponse {
        do {
            return try await connection.start(url, configuration: configuration)
        } catch {
            connection.cancel()
            throw error
        }
    }

    /// Stops reading and closes the connection.
    public func close() {
        source.cancel()
        connection.cancel()
    }

    // MARK: - Stream types

    static func isPlaylist(path: String, contentType: String?) -> Bool {
        if let contentType {
            return ["audio/x-scpls", "audio/scpls", "audio/x-mpegurl", "audio/mpegurl"].contains(contentType.lowercased())
        }
        return ["pls", "m3u"].contains((path as NSString).pathExtension.lowercased())
    }

    /// The MIME type that picks the decoder (servers say "audio/aacp" and the like).
    static func decoderType(for contentType: String?, path: String) -> String? {
        switch contentType?.lowercased() {
        case "audio/mpeg", "audio/mp3", "audio/x-mpeg", "audio/mpeg3": return "audio/mpeg"
        case "audio/aac", "audio/aacp", "audio/x-aac", "audio/x-aacp": return "audio/aac"
        case "audio/ogg", "application/ogg", "audio/x-ogg": return "audio/ogg; codecs=vorbis"
        case "audio/opus": return "audio/ogg; codecs=opus"
        case "application/vnd.apple.mpegurl", "application/x-mpegurl": return nil  // HLS
        default:
            switch (path as NSString).pathExtension.lowercased() {
            case "aac": return "audio/aac"
            case "ogg": return "audio/ogg; codecs=vorbis"
            case "opus": return "audio/ogg; codecs=opus"
            case "m3u8": return nil
            default: return "audio/mpeg"  // what most stations send
            }
        }
    }

    /// The first stream in a .pls or .m3u station playlist.
    static func resolve(playlist url: URL, configuration: URLSessionConfiguration) async throws -> URL {
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // Station playlists are a few lines; a link that is really a stream
        // would never end, so reading stops at 256 KB.
        let (bytes, _) = try await session.bytes(from: url)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 256 * 1024 { break }
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
            let first = firstStream(inPlaylist: text)
        else { throw LiveStreamError("No stream in the station's playlist") }
        return first
    }

    static func firstStream(inPlaylist text: String) -> URL? {
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            // PLS: File1=http://...; M3U: a bare URL line.
            let candidate = line.lowercased().hasPrefix("file") ? line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? "" : line
            if let url = URL(string: candidate.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(url.scheme?.lowercased()) {
                return url
            }
        }
        return nil
    }
}

public struct LiveStreamError: LocalizedError, Sendable {
    public let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The HTTP side: feeds the input source and takes ICY metadata out of the audio.
final class LiveConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: LiveInputSource
    private let onTitle: @Sendable (String) -> Void
    private var session: URLSession?
    private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    private let lock = NSLock()

    /// ICY: `metaInterval` audio bytes, then a length byte (x16) of metadata.
    private var metaInterval = 0
    private var audioLeft = 0
    private var metadataLeft: Int?
    private var metadata = Data()
    private var lastTitle: String?

    init(source: LiveInputSource, onTitle: @escaping @Sendable (String) -> Void) {
        self.source = source
        self.onTitle = onTitle
    }

    /// Connects and returns the response once its headers are in.
    func start(_ url: URL, configuration: URLSessionConfiguration) async throws -> URLResponse {
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("Hagtamp", forHTTPHeaderField: "User-Agent")
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { responseContinuation = continuation }
            session.dataTask(with: request).resume()
        }
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
    }

    private func resumeResponse(with result: Result<URLResponse, Error>) {
        let continuation = lock.withLock {
            defer { responseContinuation = nil }
            return responseContinuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                resumeResponse(with: .failure(LiveStreamError("The station answered HTTP \(http.statusCode)")))
                completionHandler(.cancel)
                return
            }
            metaInterval = Int(http.value(forHTTPHeaderField: "icy-metaint") ?? "") ?? 0
            audioLeft = metaInterval
        }
        resumeResponse(with: .success(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard metaInterval > 0 else {
            source.append(data)
            return
        }
        var audio = Data()
        var index = data.startIndex
        while index < data.endIndex {
            if let left = metadataLeft {
                let take = min(left, data.endIndex - index)
                metadata.append(data[index..<index + take])
                index += take
                metadataLeft = left - take
                if metadataLeft == 0 {
                    metadataLeft = nil
                    audioLeft = metaInterval
                    report(metadata)
                    metadata.removeAll()
                }
            } else if audioLeft > 0 {
                let take = min(audioLeft, data.endIndex - index)
                audio.append(data[index..<index + take])
                index += take
                audioLeft -= take
            } else {
                let length = Int(data[index]) * 16
                index += 1
                if length == 0 {
                    audioLeft = metaInterval
                } else {
                    metadataLeft = length
                }
            }
        }
        if !audio.isEmpty { source.append(audio) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        resumeResponse(with: .failure(error ?? LiveStreamError("The station closed the connection")))
        source.finishWithError(error)
    }

    private func report(_ block: Data) {
        guard let title = Self.streamTitle(in: block), title != lastTitle else { return }
        lastTitle = title
        onTitle(title)
    }

    /// "StreamTitle='Artist - Song';StreamUrl='';" (UTF-8, or Latin-1 from older servers).
    static func streamTitle(in block: Data) -> String? {
        let bytes = block.prefix { $0 != 0 }
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1),
            let start = text.range(of: "StreamTitle='")
        else { return nil }
        let rest = text[start.upperBound...]
        let title = rest.range(of: "';").map { rest[..<$0.lowerBound] } ?? rest
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
