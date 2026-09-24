import Foundation
import PlayerCore
import SFBAudioEngine

extension TrackInfo {
    /// Reads tags and properties; files the decoders can't parse still get a name.
    public static func read(from url: URL) -> TrackInfo {
        var info = TrackInfo(url: url)
        guard url.isFileURL, let file = try? AudioFile(readingPropertiesAndMetadataFrom: url) else { return info }
        info.title = file.metadata.title
        info.artist = file.metadata.artist
        info.album = file.metadata.albumTitle
        let properties = file.properties
        info.duration = properties.duration
        info.sampleRate = properties.sampleRate
        info.channels = properties.channelCount.map(Int.init)
        info.bitrate = properties.bitrate.map { Int($0.rounded()) }
        return info
    }

    /// File extensions the decoders handle (for open panels and folder scans).
    public static var supportedExtensions: Set<String> {
        AudioDecoder.supportedPathExtensions
    }
}
