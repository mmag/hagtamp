import Foundation
@preconcurrency import SFBAudioEngine
import StreamingInput

/// A track the engine plays while it is still downloading.
///
/// The decoder sees an unseekable stream until the download is complete,
/// so seeking has to wait for the finished file.
public final class StreamingTrack: @unchecked Sendable {
    /// Formats whose decoders can start from the head of an unseekable
    /// file. Others need the whole download: MP4 may keep its index at the
    /// end, and SFBAudioEngine's Vorbis decoder reports failed seeks as
    /// successes, so vorbisfile would read the wrong bytes.
    public static func canStream(fileExtension: String) -> Bool {
        ["mp3", "flac", "opus"].contains(fileExtension.lowercased())
    }

    /// Where the file ends up once downloaded (its extension picks the decoder).
    public let url: URL
    public let state: StreamState
    private let source: StreamingInputSource
    let decoder: AudioDecoder

    public init(url: URL, partialFile: URL, state: StreamState) throws {
        self.url = url
        self.state = state
        source = StreamingInputSource(url: url, partialFile: partialFile, state: state)
        // No content sniffing here: it would read (and wait) on the calling thread.
        decoder = try AudioDecoder(inputSource: source, detectContentType: false, mimeTypeHint: nil)
    }

    /// Stops reading (the player moved on); the download itself continues into the cache.
    func cancel() {
        source.cancel()
    }
}

/// What the player hands to the engine: a complete file or a stream.
public enum PlayableSource: Sendable {
    case file(URL)
    case stream(StreamingTrack)

    public var url: URL {
        switch self {
        case .file(let url): url
        case .stream(let track): track.url
        }
    }

    var stream: StreamingTrack? {
        if case .stream(let track) = self { track } else { nil }
    }

    func decoder() throws -> AudioDecoder {
        switch self {
        case .file(let url): try AudioDecoder(url: url)
        case .stream(let track): track.decoder
        }
    }
}
