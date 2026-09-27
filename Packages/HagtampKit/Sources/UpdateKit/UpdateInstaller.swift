import CoreServices
import CryptoKit
import Foundation
import Security

/// Installing a release over the running app: download the archive (its
/// size and checksum must match what GitHub lists), unpack it, check the app
/// in it (the same bundle identifier, the promised version, a code
/// signature that holds) and swap it in where the old one was.
public enum UpdateInstaller {
    /// Why the app at `installed` can't be replaced where it is, if it can't.
    public static func obstacle(replacing installed: URL) -> String? {
        if installed.path.contains("/AppTranslocation/") {
            return "macOS runs this copy of Hagtamp from a temporary place. Move it to the Applications folder to update it in place."
        }
        let manager = FileManager.default
        guard manager.isWritableFile(atPath: installed.path), manager.isWritableFile(atPath: installed.deletingLastPathComponent().path) else {
            return "Hagtamp can't write to the folder it is in."
        }
        return nil
    }

    /// Downloads `asset` into `folder`; `progress` gets 0...1 as it arrives.
    public static func download(
        _ asset: Release.Asset, into folder: URL, session: URLSession = .shared, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let destination = folder.appendingPathComponent(asset.name)
        try? FileManager.default.removeItem(at: destination)
        let download = Download()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: asset.url) { temporary, response, error in
                    do {
                        if let error { throw error }
                        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                            throw UpdateError("The download failed with status \(http.statusCode).")
                        }
                        guard let temporary else { throw UpdateError("The download failed.") }
                        try FileManager.default.moveItem(at: temporary, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                download.start(task, progress: progress)
            }
        } onCancel: {
            download.cancel()
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard size == asset.size else { throw UpdateError("The download is incomplete.") }
        if let expected = asset.sha256, try sha256(of: destination) != expected {
            throw UpdateError("The download is damaged: its checksum doesn't match.")
        }
        return destination
    }

    /// A download task that may be called off before it has started.
    private final class Download: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var observation: NSKeyValueObservation?
        private var cancelled = false

        func start(_ task: URLSessionDownloadTask, progress: @escaping @Sendable (Double) -> Void) {
            lock.withLock {
                self.task = task
                observation = task.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
            }
            task.resume()
            if lock.withLock({ cancelled }) { task.cancel() }
        }

        func cancel() {
            let task = lock.withLock {
                cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unzips an archive into `folder` the way Finder does (ditto) and finds
    /// the app in it. Blocks: call it off the main thread.
    public static func unpack(_ archive: URL, into folder: URL) throws -> URL {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError("The download couldn't be unpacked.") }
        let apps = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw UpdateError("The download doesn't hold the app.") }
        return apps[0]
    }

    /// The app must be this one, of the promised version, and intact.
    public static func validate(_ app: URL, bundleIdentifier: String, version: AppVersion) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError("The download holds a different app.")
        }
        let found = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        guard found == version else {
            throw UpdateError("The download is version \(found?.description ?? "unknown"), not \(version).")
        }
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
        else { throw UpdateError("The downloaded app is damaged: its code signature doesn't hold.") }
    }

    /// Swaps `app` in where `installed` is; the old version goes. The running
    /// app keeps running from memory until it quits. Launch Services is told
    /// about the new version before anything opens it.
    public static func replace(_ installed: URL, with app: URL) throws {
        _ = try FileManager.default.replaceItemAt(installed, withItemAt: app)
        LSRegisterURL(installed as CFURL, true)
    }
}
