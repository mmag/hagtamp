import Foundation
import PlayerCore

/// Navidrome songs in playlists: `hagtamp-nd://song/<id>`. The player turns
/// them into cached local files before playing.
public enum NavidromeTrack {
    public static let scheme = "hagtamp-nd"

    public static func url(songID: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "song"
        components.path = "/" + songID
        return components.url!
    }

    public static func songID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "song" else { return nil }
        let id = String(url.path.dropFirst())
        return id.isEmpty ? nil : id
    }

    public static func info(for song: NavidromeSong) -> TrackInfo {
        var info = TrackInfo(url: url(songID: song.id), title: song.title, artist: song.artist, duration: song.duration.map(Double.init))
        info.album = song.album
        info.bitrate = song.bitRate
        info.sampleRate = song.samplingRate.map(Double.init)
        info.channels = song.channelCount
        return info
    }
}
