import Foundation

// Secure per-provider OAuth token storage (access + refresh + expiry) in the
// Keychain. Replaces ad-hoc token files; used by the direct-REST connectors.

enum TokenStore {
    private static func account(_ provider: String) -> String { "oauth-\(provider)" }

    static func save(_ provider: String, _ tokens: OAuthTokens) {
        let dict: [String: Any] = [
            "access": tokens.access,
            "refresh": tokens.refresh ?? "",
            "expiry": tokens.expiryMs
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            Keychain.set(json, account: account(provider))
        }
    }

    static func load(_ provider: String) -> OAuthTokens? {
        guard let json = Keychain.get(account: account(provider)),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = dict["access"] as? String else { return nil }
        let refresh = (dict["refresh"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expiry = (dict["expiry"] as? Double) ?? 0
        return OAuthTokens(access: access, refresh: refresh, expiryMs: expiry)
    }

    static func exists(_ provider: String) -> Bool { Keychain.exists(account: account(provider)) }

    static func updateAccess(_ provider: String, access: String, expiryMs: Double) {
        guard let current = load(provider) else { return }
        save(provider, OAuthTokens(access: access, refresh: current.refresh, expiryMs: expiryMs))
    }
}
