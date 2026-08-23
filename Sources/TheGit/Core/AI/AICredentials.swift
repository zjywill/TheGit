import Foundation
import Security

/// API keys, in a file only this account can read —
/// `~/Library/Application Support/TheGit/ai-keys.json`, mode 0600, one entry
/// per provider so switching providers doesn't lose the other's key.
///
/// They used to live in the login keychain, which protects them better at
/// rest. The keychain identifies an app by its code signature, though, and a
/// `swift build` binary is ad-hoc signed with a fresh identity on every
/// rebuild — so it asked for the keychain password again and again. This is
/// the trade that was made: a key readable by anything already running as
/// this user, in exchange for never being asked.
enum AICredentials {
    /// Where the file lives. A test points this at a temporary directory;
    /// nothing else has any business writing to it.
    static var directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "TheGit")
    }()

    static var file: URL { directory.appending(path: "ai-keys.json") }

    static func key(for providerID: String) -> String? {
        guard let key = load()[providerID], !key.isEmpty else { return nil }
        return key
    }

    static func hasKey(for providerID: String) -> Bool { key(for: providerID) != nil }

    /// nil or empty removes the entry — that's how the settings field clears
    /// a key.
    static func setKey(_ key: String?, for providerID: String) {
        var keys = load()
        if let key, !key.isEmpty {
            keys[providerID] = key
        } else {
            keys.removeValue(forKey: providerID)
        }
        save(keys)
    }

    // MARK: - Storage

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let keys = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return keys
    }

    private static func save(_ keys: [String: String]) {
        let manager = FileManager.default
        // 0700: the directory listing alone says which providers are
        // configured, which is nobody else's business either.
        try? manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(keys) else { return }
        // Written through Data rather than createFile so an existing file is
        // replaced atomically; the mode is then set on whatever landed, since
        // a replacement inherits nothing from the file it replaced.
        try? data.write(to: file, options: [.atomic])
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: - Leaving the keychain behind

    private static let service = "com.zjywill.TheGit.ai"
    private static let migrationFlag = "TheGit.ai.keychainMigrated"

    /// Moves whatever the keychain still holds into the file, once, and takes
    /// it back out of the keychain.
    ///
    /// Listing the accounts doesn't touch the secrets and never prompts;
    /// reading one may, exactly once per configured provider, on a build the
    /// keychain doesn't recognise. Better than silently dropping a key the
    /// user pasted in a previous version.
    ///
    /// Called from `AISettings` rather than from the accessors above, so that
    /// nothing which merely reads a key — a test, in particular — can reach
    /// into the real keychain and start deleting from it.
    static func adoptKeychainItems() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationFlag) else { return }
        defaults.set(true, forKey: migrationFlag)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let entries = items as? [[String: Any]]
        else { return }

        var keys = load()
        for entry in entries {
            guard let account = entry[kSecAttrAccount as String] as? String else { continue }

            query = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            var read = query
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            guard SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let key = String(data: data, encoding: .utf8), !key.isEmpty
            else {
                // Denied at the prompt, or unreadable. The item stays where it
                // is: deleting a secret we failed to copy would destroy the one
                // thing here the user cannot retype. The flag is still set, so
                // this asks once and never again — the key is in Keychain
                // Access if they want it back.
                continue
            }
            if keys[account] == nil { keys[account] = key }
            // Safe now that the key is in hand: a copy left behind is a copy
            // of a secret the user asked us to stop keeping there.
            SecItemDelete(query as CFDictionary)
        }
        save(keys)
    }
}
