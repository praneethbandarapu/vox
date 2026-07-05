import Foundation

// Secret store. Backed by a chmod-600 JSON file at ~/.vox/secrets.json
// (owner-only, outside the repo), not the macOS Keychain.
//
// Why not the Keychain: without an Apple Developer team ID, the Keychain
// re-prompts for access on every rebuild/update because the app's signature
// changes and it can't recognize "the same app". A user-only file (the same
// pattern as ~/.aws/credentials, and where our gcp-oauth.keys.json already
// lives) avoids that entirely. Move back to the Keychain if the app is ever
// signed with a real Developer ID. (Type kept named `Keychain` for now to
// avoid churn across call sites.)

enum Keychain {
    private static var path: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.vox/secrets.json"
    }
    private static let lock = NSLock()
    private static var cache: [String: String]?

    private static func loadAll() -> [String: String] {
        if let cache { return cache }
        var dict: [String: String] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            dict = obj
        }
        cache = dict
        return dict
    }

    private static func saveAll(_ dict: [String: String]) {
        cache = dict
        let dir = FileManager.default.homeDirectoryForCurrentUser.path + "/.vox"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    static func get(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadAll()[account]
    }

    static func exists(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadAll()[account] != nil
    }

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var dict = loadAll()
        dict[account] = value
        saveAll(dict)
        return true
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var dict = loadAll()
        dict[account] = nil
        saveAll(dict)
        return true
    }
}
