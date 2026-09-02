import Foundation
import Security

/// Secrets live in the login keychain, not in a dotfile. The bash installer
/// wrote `~/.agent-inbox/bot-token` with mode 600; this is the upgrade.
enum Keychain {
    private static let service = "com.ideaplaces.agent-inbox"

    static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }
}

/// What `AppSettings` needs from a keychain, so a test can hand it memory.
///
/// The login keychain is shared with the installed app: a test that read
/// from it would see the developer's real token, and one that wrote to it
/// would delete it. Every test therefore gets an in-memory store and the app
/// gets the real thing.
protocol SecretStore {
    func get(_ account: String) -> String?
    func set(_ value: String?, for account: String)
}

struct LoginKeychain: SecretStore {
    func get(_ account: String) -> String? { Keychain.get(account) }
    func set(_ value: String?, for account: String) { Keychain.set(value, for: account) }
}
