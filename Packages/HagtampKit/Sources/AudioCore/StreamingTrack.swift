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

    /// Waits for the download to end; true when it completed.
    public func downloaded() async -> Bool {
        while !state.finished {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return false }
        }
        return state.error == nil
    }
}

/// What the player hands to the engine: a complete file, a download in
/// progress, or a live stream.
public enum PlayableSource: Sendable {
    case file(URL)
    case stream(StreamingTrack)
    case live(LiveStream)

    public var url: URL {
        switch self {
        case .file(let url): url
        case .stream(let track): track.url
        case .live(let stream): stream.url
        }
    }

    public var isLive: Bool {
        if case .live = self { true } else { false }
    }

    /// Lets go of a source that won't be played (a live stream's connection stays open until then).
    public func discard() {
        if case .live(let stream) = self { stream.close() }
    }

    /// What the engine cancels once the player is done with this source.
    var release: (@Sendable () -> Void)? {
        switch self {
        case .file: nil
        case .stream(let track): { track.cancel() }
        case .live(let stream): { stream.close() }
        }
    }

    func decoder() throws -> any PCMDecoding {
        switch self {
        case .file(let url): try AudioDecoder(url: url)
        case .stream(let track): track.decoder
        case .live(let stream): stream.decoder
        }
    }
}
