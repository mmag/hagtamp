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

    /// What a skin is made of; other files in an archive or folder are left alone.
    static let usedExtensions: Set<String> = ["bmp", "png", "txt", "cur", "ani"]
    /// Real skins stay far below these (their largest file is about 1.4 MB):
    /// they keep a damaged or hostile archive from filling the memory.
    static let maxFileSize = 16 << 20
    static let maxTotalSize = 64 << 20
    static let maxFolderItems = 5000

    private struct TooLarge: Error {}

    static func isUsed(_ path: String) -> Bool {
        usedExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public init(zipData: Data) throws {
        let archive = try Archive(data: zipData, accessMode: .read)
        var entries: [Entry] = []
        var total = 0
        for entry in archive where entry.type == .file && Self.isUsed(entry.path) {
            var data = Data()
            do {
                // Counted while inflating: the sizes in the archive's directory can lie.
                _ = try archive.extract(entry, skipCRC32: true) { chunk in
                    guard data.count + chunk.count <= Self.maxFileSize, total + data.count + chunk.count <= Self.maxTotalSize else { throw TooLarge() }
                    data.append(chunk)
                }
            } catch {
                // Like Winamp, a damaged member only loses that file.
                continue
            }
            total += data.count
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
        var seen = 0, total = 0
        for case let url as URL in enumerator {
            seen += 1
            guard seen <= Self.maxFolderItems else { break }  // not a skin folder
            guard Self.isUsed(url.path), (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxFileSize, total + size <= Self.maxTotalSize else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            let data = try Data(contentsOf: url)
            total += data.count
            entries.append(Entry(path: path, data: data))
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
