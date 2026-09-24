import AppKit
import ClassicUI
import MediaPlayer
import PlayerCore

/// The Mac's media controls: media keys, headphones, Control Center and the
/// Now Playing widget drive the player, and they show what it plays.
@MainActor
final class NowPlaying {
    private let model: PlayerModel
    private let cover: (URL) async -> NSImage?
    /// What was last published, to publish only changes (and jumps in time).
    private var published: (url: URL?, name: String?, status: PlaybackStatus, duration: Double?)?
    private var publishedElapsed: (seconds: Double, at: Date)?
    private var artwork: (url: URL, image: MPMediaItemArtwork?)?

    init(model: PlayerModel, cover: @escaping (URL) async -> NSImage?) {
        self.model = model
        self.cover = cover
        let commands = MPRemoteCommandCenter.shared()
        on(commands.playCommand) { model, _ in if model.status != .playing { model.play() } }
        on(commands.pauseCommand) { model, _ in if model.status == .playing { model.pause() } }
        on(commands.togglePlayPauseCommand) { model, _ in model.status == .playing ? model.pause() : model.play() }
        on(commands.stopCommand) { model, _ in model.stop() }
        on(commands.nextTrackCommand) { model, _ in model.next() }
        on(commands.previousTrackCommand) { model, _ in model.previous() }
        on(commands.changePlaybackPositionCommand) { model, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent, let duration = model.duration, duration > 0 else { return }
            model.seek(to: event.positionTime / duration)
        }
    }

    /// Remote commands arrive on the main thread.
    private func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerModel, MPRemoteCommandEvent) -> Void) {
        command.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return .commandFailed }
                action(self.model, event)
                return .success
            }
        }
    }

    /// Publishes the player's state when something the Mac shows changed.
    func update() {
        let track = model.displayedTrack
        let status = model.status
        let duration = model.duration
        let elapsed = model.elapsed
        let now = (url: track?.url, name: track?.displayName, status: status, duration: duration)
        let expected = publishedElapsed.map { $0.seconds + (published?.status == .playing ? Date().timeIntervalSince($0.at) : 0) }
        let jumped = expected.map { abs($0 - elapsed) > 1.5 } ?? true
        if let published, published.url == now.url, published.name == now.name, published.status == now.status,
            published.duration == now.duration, !jumped
        {
            return
        }
        published = now
        publishedElapsed = (elapsed, Date())

        let center = MPNowPlayingInfoCenter.default()
        guard let track, status != .stopped || model.currentTrack != nil else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title ?? track.displayName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: status == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: duration == nil && status != .stopped,
        ]
        if let artist = track.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if artwork?.url == track.url, let image = artwork?.image { info[MPMediaItemPropertyArtwork] = image }
        center.nowPlayingInfo = info
        center.playbackState = status == .playing ? .playing : status == .paused ? .paused : .stopped
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = duration != nil

        if artwork?.url != track.url {
            let url = track.url
            artwork = (url, nil)
            Task { [weak self] in
                guard let image = await self?.cover(url), self?.artwork?.url == url else { return }
                self?.artwork = (url, Self.artwork(for: image))
                self?.published = nil  // republish with the artwork
                self?.update()
            }
        }
    }

    /// MediaPlayer asks for the image on its own queue, not the main actor.
    private nonisolated static func artwork(for image: NSImage) -> MPMediaItemArtwork {
        nonisolated(unsafe) let image = image
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    /// For the self test.
    var summary: String {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let title = info[MPMediaItemPropertyTitle] as? String ?? "-"
        let duration = (info[MPMediaItemPropertyPlaybackDuration] as? Double).map { String(format: "%.1f", $0) } ?? "-"
        let state = MPNowPlayingInfoCenter.default().playbackState
        return "title=\(title) duration=\(duration) state=\(state.rawValue) artwork=\(info[MPMediaItemPropertyArtwork] != nil)"
    }
}
