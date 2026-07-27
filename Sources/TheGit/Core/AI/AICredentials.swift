import Foundation
import Security

/// API keys, in the login keychain — one item per provider, so switching
/// providers doesn't lose the other's key. Never UserDefaults: that plist
/// is world-readable inside the user's home directory.
///
/// A `swift build` binary is ad-hoc signed and gets a new identity on every
/// rebuild, so the debug app asks for keychain permission again after each
/// build. The bundled .app doesn't.
enum AICredentials {
    private static let service = "com.zjywill.TheGit.ai"

    static func key(for providerID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    static func hasKey(for providerID: String) -> Bool { key(for: providerID) != nil }

    /// nil or empty removes the item — that's how the settings field
    /// clears a key.
    static func setKey(_ key: String?, for providerID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
        ]
        SecItemDelete(query as CFDictionary)

        guard let key, !key.isEmpty, let data = key.data(using: .utf8) else { return }
        var item = query
        item[kSecValueData as String] = data
        // Keys are useless before first unlock and shouldn't sync.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
