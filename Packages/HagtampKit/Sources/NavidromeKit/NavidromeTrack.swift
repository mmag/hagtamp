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
        // Zeros and no peak: a server filling in what the tags lack.
        info.replayGain = song.replayGain.flatMap {
            $0.trackGain == 0 && ($0.trackPeak ?? 0) == 0
                ? nil : Loudness(tagged: $0.trackGain, trackPeak: $0.trackPeak, albumGain: $0.albumGain, albumPeak: $0.albumPeak)
        }
        return info
    }
}
