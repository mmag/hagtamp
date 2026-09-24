import CoreServices
import Foundation

/// Calls back when anything changes under some folders (FSEvents). Events
/// are coalesced over `latency` seconds, so a batch copy is one callback.
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "hagtamp.folder-watcher")

    public init(_ folders: [URL], latency: TimeInterval = 3, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, folders.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
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
}
