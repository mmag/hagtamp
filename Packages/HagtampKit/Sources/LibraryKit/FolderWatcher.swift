import CoreServices
import Foundation

/// Calls back when files that matter change under some folders (FSEvents).
/// Events are coalesced over `latency` seconds, so a batch copy is one callback.
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void
    private let extensions: Set<String>?
    private let ignored: [String]
    private let queue = DispatchQueue(label: "hagtamp.folder-watcher")

    /// `extensions`: the files that matter (nil: all). Changes in `ignoring`,
    /// in hidden folders and in ~/Library never do: a library folder may be
    /// the home folder, where the app keeps its own files.
    public init(
        _ folders: [URL], latency: TimeInterval = 3, extensions: Set<String>? = nil, ignoring: [URL] = [],
        onChange: @escaping @Sendable () -> Void
    ) {
        self.onChange = onChange
        self.extensions = extensions
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        self.ignored = (ignoring + [library]).flatMap { url -> [String] in
            let path = url.standardizedFileURL.path
            let resolved = realpath(path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            }
            return Set([path, resolved].compactMap { $0 }).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        }
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if (0..<min(count, list.count)).contains(where: { watcher.matters(list[$0], flags[$0]) }) { watcher.onChange() }
        }
        let options = kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot  // a folder on a disk mounted later
        stream = FSEventStreamCreate(
            nil, callback, &context, folders.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(options))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    func matters(_ path: String, _ flags: FSEventStreamEventFlags) -> Bool {
        // Events were lost or a whole tree changed (a disk mounted): look again.
        let rescan = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
        if flags & FSEventStreamEventFlags(rescan) != 0 { return true }
        if ignored.contains(where: { path.hasPrefix($0) || path + "/" == $0 }) || path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
            return false
        }
        guard let extensions else { return true }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
            // A folder of music appearing, going or renamed.
            let changes = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
            return flags & FSEventStreamEventFlags(changes) != 0
        }
        return extensions.contains((path as NSString).pathExtension.lowercased())
    }
}
