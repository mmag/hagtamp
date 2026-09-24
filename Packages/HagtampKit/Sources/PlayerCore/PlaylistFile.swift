import Foundation

/// Playlist files: M3U/M3U8 (with #EXTINF) and PLS.
public enum PlaylistFile {
    public static let extensions: Set<String> = ["m3u", "m3u8", "pls"]

    public enum Format: Sendable {
        case m3u8, pls
    }

    public static func isPlaylist(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    public static func read(_ url: URL) throws -> [TrackInfo] {
        try parse(Data(contentsOf: url), base: url.deletingLastPathComponent())
    }

    /// Entries with their titles/lengths from the file; `base` resolves relative paths.
    public static func parse(_ data: Data, base: URL) -> [TrackInfo] {
        // .m3u8 is UTF-8; plain .m3u was written in the ANSI code page, but is often UTF-8 too.
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        let content = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        let lines = content.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.first(where: { !$0.isEmpty })?.lowercased() == "[playlist]" {
            return parsePLS(lines, base: base)
        }
        return parseM3U(lines, base: base)
    }

    private static func parseM3U(_ lines: [String], base: URL) -> [TrackInfo] {
        var result: [TrackInfo] = []
        var pending: (title: String?, duration: Double?)?
        for line in lines where !line.isEmpty {
            if line.hasPrefix("#") {
                // #EXTINF:<seconds>,<title>
                if line.uppercased().hasPrefix("#EXTINF:") {
                    let body = line.dropFirst("#EXTINF:".count)
                    let comma = body.firstIndex(of: ",")
                    let seconds = Double(body[..<(comma ?? body.endIndex)].trimmingCharacters(in: .whitespaces))
                    let title = comma.map { String(body[body.index(after: $0)...]) }
                    pending = (title, seconds.flatMap { $0 > 0 ? $0 : nil })
                }
                continue
            }
            guard let url = resolve(line, base: base) else { continue }
            var info = TrackInfo(url: url, duration: pending?.duration)
            info.title = pending?.title
            result.append(info)
            pending = nil
        }
        return result
    }

    private static func parsePLS(_ lines: [String], base: URL) -> [TrackInfo] {
        var files: [Int: String] = [:], titles: [Int: String] = [:], lengths: [Int: Double] = [:]
        for line in lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].lowercased(), value = String(line[line.index(after: eq)...])
            for (prefix, apply) in [
                ("file", { (n: Int) in files[n] = value }),
                ("title", { (n: Int) in titles[n] = value }),
                ("length", { (n: Int) in lengths[n] = Double(value) }),
            ] as [(String, (Int) -> Void)] {
                if key.hasPrefix(prefix), let n = Int(key.dropFirst(prefix.count)) { apply(n) }
            }
        }
        return files.keys.sorted().compactMap { n in
            guard let url = resolve(files[n]!, base: base) else { return nil }
            var info = TrackInfo(url: url, duration: lengths[n].flatMap { $0 > 0 ? $0 : nil })
            info.title = titles[n]
            return info
        }
    }

    /// Absolute paths, URLs (file, http, our own schemes), and paths relative
    /// to the playlist (Windows separators too).
    static func resolve(_ entry: String, base: URL) -> URL? {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // A one-letter "scheme" is a Windows drive ("C:\Music\...").
        if let url = URL(string: trimmed), let scheme = url.scheme, scheme.count > 1 {
            return url
        }
        let path = trimmed.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        // Resolve against the folder itself, not its parent.
        let folder = URL(fileURLWithPath: base.path, isDirectory: true)
        return URL(fileURLWithPath: path, relativeTo: folder).standardizedFileURL
    }

    // MARK: - Writing

    /// Paths are written relative to the playlist when the files live under its folder.
    public static func data(for tracks: [TrackInfo], format: Format, base: URL) -> Data {
        let basePath = base.standardizedFileURL.path + "/"
        func location(_ url: URL) -> String {
            guard url.isFileURL else { return url.absoluteString }
            let path = url.standardizedFileURL.path
            return path.hasPrefix(basePath) ? String(path.dropFirst(basePath.count)) : path
        }
        var text: String
        switch format {
        case .m3u8:
            text = "#EXTM3U\n"
            for track in tracks {
                text += "#EXTINF:\(track.duration.map { Int($0.rounded()) } ?? -1),\(track.displayName)\n"
                text += location(track.url) + "\n"
            }
        case .pls:
            text = "[playlist]\n"
            for (i, track) in tracks.enumerated() {
                text += "File\(i + 1)=\(location(track.url))\n"
                text += "Title\(i + 1)=\(track.displayName)\n"
                text += "Length\(i + 1)=\(track.duration.map { Int($0.rounded()) } ?? -1)\n"
            }
            text += "NumberOfEntries=\(tracks.count)\nVersion=2\n"
        }
        return Data(text.utf8)
    }
}
