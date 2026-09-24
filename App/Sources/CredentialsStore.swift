import Foundation
import NavidromeKit

/// Navidrome logins, kept in the app's own folder (readable by the user
/// only). Only a token and its salt are stored, never the password: the
/// Subsonic API takes them in its place.
///
/// Not the Keychain: its items trust the exact build that made them, so
/// every rebuild of an ad-hoc signed app asked for the keychain password.
enum CredentialsStore {
    private static var file: URL { Storage.supportDirectory.appendingPathComponent("credentials.json") }

    static func credentials(for account: String) -> NavidromeCredentials? {
        all()[account]
    }

    static func set(_ credentials: NavidromeCredentials?, for account: String) {
        var saved = all()
        saved[account] = credentials
        guard let data = try? JSONEncoder().encode(saved) else { return }
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    private static func all() -> [String: NavidromeCredentials] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: NavidromeCredentials].self, from: $0) } ?? [:]
    }
}
