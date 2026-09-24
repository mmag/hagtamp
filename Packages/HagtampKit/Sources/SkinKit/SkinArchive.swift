import Foundation
import ZIPFoundation

/// Read access to the files of a skin, packed (`.wsz`/`.zip`) or unpacked (a folder).
///
/// Lookups follow Winamp's behaviour on a case-insensitive file system: names
/// match regardless of case and of the folder they are in, and when several
/// entries collide the last one wins (it would overwrite the others when
/// Winamp unpacks the archive).
public struct SkinArchive: Sendable {
    public struct Entry: Sendable {
        public let path: String
        public let data: Data
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(contentsOf url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try self.init(directory: url)
        } else {
            try self.init(zipData: Data(contentsOf: url))
        }
    }

    public init(zipData: Data) throws {
        let archive = try Archive(data: zipData, accessMode: .read)
        var entries: [Entry] = []
        for entry in archive where entry.type == .file {
            var data = Data()
            do {
                _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
            } catch {
                // Like Winamp, a damaged member only loses that file.
                continue
            }
            entries.append(Entry(path: entry.path, data: data))
        }
        self.init(entries: entries)
    }

    public init(directory: URL) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var entries: [Entry] = []
        let base = directory.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            entries.append(Entry(path: path, data: try Data(contentsOf: url)))
        }
        self.init(entries: entries.sorted { $0.path < $1.path })
    }

    /// Finds `name.ext` for any of `extensions`, ignoring case and folders.
    public func file(_ name: String, extensions: [String]) -> Entry? {
        let wanted = Set(extensions.map { "\(name).\($0)".lowercased() })
        return entries.last { entry in
            let fileName = entry.path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? ""
            return wanted.contains(fileName.lowercased())
        }
    }

    public func text(_ name: String, extension ext: String = "txt") -> String? {
        file(name, extensions: [ext]).map { Self.decodeText($0.data) }
    }

    /// Skin text files are ANSI (Windows-1252 in practice).
    static func decodeText(_ data: Data) -> String {
        String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}
