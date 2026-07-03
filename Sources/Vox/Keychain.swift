import Foundation
import Security

// Thin wrapper over the macOS Keychain (Security framework).
// Secrets are stored encrypted by the OS, scoped to this user.
// Nothing here ever writes a secret to disk in plaintext or to the repo.

enum Keychain {
    static let service = "ai.vox"

    // In-memory cache so a key is decrypted from the Keychain at most once per
    // session (avoids a permission prompt on every read).
    private static let cacheLock = NSLock()
    private static var cache: [String: String] = [:]

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Replace any existing item.
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess {
            cacheLock.lock(); cache[account] = value; cacheLock.unlock()
        }
        return status == errSecSuccess
    }

    // Checks whether a secret exists WITHOUT decrypting it. Reading only the
    // attributes (not the data) does not trigger a Keychain access prompt, so
    // this is safe to call at startup / when building the menu.
    static func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func get(account: String) -> String? {
        cacheLock.lock()
        if let cached = cache[account] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        cacheLock.lock(); cache[account] = value; cacheLock.unlock()
        return value
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        cacheLock.lock(); cache[account] = nil; cacheLock.unlock()
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
