import Foundation

// Google connect via our own in-app OAuth flow (Calendar + Gmail, user token),
// replacing the npx `auth` step. Reuses the existing Desktop OAuth client id/secret
// from ~/.vox/gcp-oauth.keys.json. Tokens land in the Keychain via TokenStore.

enum GoogleAuth {
    static let provider = "google"

    static func config() -> OAuthConfig? {
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/.vox/gcp-oauth.keys.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = obj["installed"] as? [String: Any],
              let clientID = installed["client_id"] as? String,
              let clientSecret = installed["client_secret"] as? String else {
            logf("[google] missing gcp-oauth.keys.json")
            return nil
        }
        return OAuthConfig(
            name: "google",
            authEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenEndpoint: "https://oauth2.googleapis.com/token",
            clientID: clientID,
            clientSecret: clientSecret,
            scopes: [
                "https://www.googleapis.com/auth/calendar",
                "https://www.googleapis.com/auth/gmail.modify"
            ],
            extraAuthParams: ["access_type": "offline", "prompt": "consent"]
        )
    }

    @discardableResult
    static func connect() async -> Bool {
        guard let cfg = config() else { return false }
        guard let tokens = await OAuthFlow.authorize(cfg) else { return false }
        TokenStore.save(provider, tokens)
        writeServerCredentials(tokens)
        logf("[google] connected (calendar + gmail)")
        return true
    }

    // Write our OAuth token into the credential files the MCP servers read, so a
    // single in-app "Connect Google" powers both the calendar and Gmail servers
    // (no per-server `npx auth`). Both servers self-refresh via the refresh token.
    static func writeServerCredentials(_ t: OAuthTokens) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cred: [String: Any] = [
            "access_token": t.access,
            "refresh_token": t.refresh ?? "",
            "scope": "https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/gmail.modify",
            "token_type": "Bearer",
            "expiry_date": t.expiryMs
        ]
        // Gmail server (@gongrzhe): top-level credentials object.
        if let data = try? JSONSerialization.data(withJSONObject: cred) {
            try? data.write(to: URL(fileURLWithPath: home + "/.vox/gmail-credentials.json"))
        }
        // Calendar server (@cocal): wraps the same object under "normal".
        if let data = try? JSONSerialization.data(withJSONObject: ["normal": cred]) {
            try? data.write(to: URL(fileURLWithPath: home + "/.vox/tokens.json"))
        }
        logf("[google] wrote MCP server credentials (calendar + gmail)")
    }

    // A valid access token, refreshing via the stored refresh token if expired.
    static func accessToken() async -> String? {
        guard let t = TokenStore.load(provider) else { return nil }
        let nowMs = Date().timeIntervalSince1970 * 1000
        if nowMs < t.expiryMs - 60_000 { return t.access }
        return await refresh(t.refresh)
    }

    private static func refresh(_ refreshToken: String?) async -> String? {
        guard let refreshToken, let cfg = config(), let secret = cfg.clientSecret else { return nil }
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let body = "grant_type=refresh_token&refresh_token=\(enc(refreshToken))&client_id=\(enc(cfg.clientID))&client_secret=\(enc(secret))"
        var req = URLRequest(url: URL(string: cfg.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String else {
                logf("[google] refresh failed: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                return nil
            }
            let expiresIn = (json["expires_in"] as? Double) ?? 3600
            TokenStore.updateAccess(provider, access: access, expiryMs: Date().timeIntervalSince1970 * 1000 + expiresIn * 1000)
            return access
        } catch {
            logf("[google] refresh error: \(error.localizedDescription)")
            return nil
        }
    }
}
