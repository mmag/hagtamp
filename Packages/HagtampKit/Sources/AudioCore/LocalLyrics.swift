import Foundation
import PlayerCore
@preconcurrency import SFBAudioEngine

extension Lyrics {
    /// A local file's lyrics: an .lrc file next to it (same name), else its lyrics tag.
    public static func local(for url: URL) -> Lyrics? {
        guard url.isFileURL else { return nil }
        let sidecar = url.deletingPathExtension().appendingPathExtension("lrc")
        if let data = try? Data(contentsOf: sidecar),
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
            let lyrics = parse(text)
        {
            return lyrics
        }
        guard let file = try? AudioFile(readingPropertiesAndMetadataFrom: url), let text = file.metadata.lyrics else { return nil }
        return parse(text)
    }
}
