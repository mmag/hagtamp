import Foundation
import SFBAudioEngine

/// Finds album art for a track: a cover image in its folder, or a picture
/// embedded in its tags.
public enum CoverArt {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "webp", "tif", "tiff", "heic"]
    /// Folder images that are clearly the cover, in order of preference.
    static let preferredNames = ["cover", "folder", "front", "album", "albumart", "albumartsmall", "thumb"]

    /// Image data for the track, or nil. Named folder images win (usually the
    /// best quality), then the embedded front cover (or any embedded picture),
    /// then any image in the folder.
    public static func imageData(for track: URL) -> Data? {
        guard track.isFileURL else { return nil }
        let images = folderImages(for: track)
        if let named = preferred(images) { return try? Data(contentsOf: named) }
        if let embedded = embeddedPicture(in: track) { return embedded }
        return images.first.flatMap { try? Data(contentsOf: $0) }
    }

    static func folderImages(for track: URL) -> [URL] {
        let folder = track.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func preferred(_ images: [URL]) -> URL? {
        for name in preferredNames {
            if let match = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) {
                return match
            }
        }
        return nil
    }

    static func embeddedPicture(in track: URL) -> Data? {
        guard let file = try? AudioFile(readingPropertiesAndMetadataFrom: track) else { return nil }
        let pictures = file.metadata.attachedPictures
        let front = pictures.first { $0.type == .frontCover }
        return (front ?? pictures.first)?.imageData
    }
}
