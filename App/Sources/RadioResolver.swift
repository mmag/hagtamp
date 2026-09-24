import AudioCore
import Foundation

/// Internet radio and other http(s) streams in the playlist (Winamp's
/// "Add URL", Navidrome's radio stations): played live as they arrive.
@MainActor
final class RadioResolver: RemoteTrackResolver {
    /// A station's song title changed (url of the playlist entry).
    var onTitle: ((String, URL) -> Void)?

    func handles(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased())
    }

    func isLive(_ url: URL) -> Bool { true }

    func cachedFile(for url: URL) -> URL? { nil }

    func prepare(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> PlayableSource {
        let stream = try await LiveStream.open(
            url,
            onTitle: { [weak self] title in Task { @MainActor in self?.onTitle?(title, url) } },
            progress: { value in Task { @MainActor in progress(value) } })
        return .live(stream)
    }
}
