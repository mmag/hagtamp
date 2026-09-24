import Foundation
import Security

/// Passwords in the login keychain (generic password items).
enum Keychain {
    private static let service = "app.hagtamp.navidrome"

    static func password(for account: String) -> String? {
        if Storage.isSelfTest { return Storage.defaults.string(forKey: "password.\(account)") }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for account: String) {
        if Storage.isSelfTest {
            Storage.defaults.set(password, forKey: "password.\(account)")
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
