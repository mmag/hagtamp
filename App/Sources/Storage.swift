import Foundation

/// Where the app keeps its settings and files. The self test gets its own
/// defaults domain and folder so it never touches the user's state.
enum Storage {
    private static let selfTestDirectory = ProcessInfo.processInfo.environment["HAGTAMP_SELFTEST"]
    static var isSelfTest: Bool { selfTestDirectory != nil }

    // UserDefaults is documented as thread-safe.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard selfTestDirectory != nil, let suite = UserDefaults(suiteName: "app.hagtamp.selftest") else { return .standard }
        suite.removePersistentDomain(forName: "app.hagtamp.selftest")
        return suite
    }()

    /// ~/Library/Application Support/Hagtamp (or the self test's output folder).
    static var supportDirectory: URL {
        let folder =
            selfTestDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hagtamp", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
