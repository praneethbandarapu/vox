import Foundation

// Direct Google Calendar client. Reads the OAuth token created during setup
// (~/.vox/tokens.json), refreshes it when expired using the client credentials
// (~/.vox/gcp-oauth.keys.json), and calls the Calendar REST API. No Claude Code,
// no npx, no filesystem roaming.

enum GoogleCalendar {
    private static var tokensPath: String { home + "/.vox/tokens.json" }
    private static var credsPath: String { home + "/.vox/gcp-oauth.keys.json" }
    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static func createEvent(_ intent: CalendarIntent) async -> String? {
        guard let token = await validAccessToken() else {
            logf("gcal: no valid access token")
            return nil
        }
        var event: [String: Any] = [
            "summary": intent.summary,
            "start": ["dateTime": intent.startISO, "timeZone": intent.timeZone],
            "end": ["dateTime": intent.endISO, "timeZone": intent.timeZone]
        ]
        if !intent.attendees.isEmpty {
            event["attendees"] = intent.attendees.map { ["email": $0] }
        }
        guard let body = try? JSONSerialization.data(withJSONObject: event) else { return nil }

        let sendUpdates = intent.attendees.isEmpty ? "none" : "all"
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events?sendUpdates=\(sendUpdates)")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
                logf("gcal create HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                return nil
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let link = json?["htmlLink"] as? String
            logf("gcal event created \(link ?? "")")
            return link ?? "created"
        } catch {
            logf("gcal error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Token handling

    private static func validAccessToken() async -> String? {
        guard let normal = loadNormalTokens() else { return nil }
        let access = normal["access_token"] as? String
        let expiry = (normal["expiry_date"] as? Double) ?? 0   // ms since epoch
        let nowMs = Date().timeIntervalSince1970 * 1000
        if let access, nowMs < expiry - 60_000 { return access }
        return await refresh(normal)
    }

    private static func loadNormalTokens() -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: tokensPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let normal = obj["normal"] as? [String: Any] else { return nil }
        return normal
    }

    private static func refresh(_ normal: [String: Any]) async -> String? {
        guard let refreshToken = normal["refresh_token"] as? String,
              let credsData = try? Data(contentsOf: URL(fileURLWithPath: credsPath)),
              let credsObj = try? JSONSerialization.jsonObject(with: credsData) as? [String: Any],
              let installed = credsObj["installed"] as? [String: Any],
              let clientId = installed["client_id"] as? String,
              let clientSecret = installed["client_secret"] as? String else { return nil }
        let tokenURI = (installed["token_uri"] as? String) ?? "https://oauth2.googleapis.com/token"

        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let form = "client_id=\(enc(clientId))&client_secret=\(enc(clientSecret))&refresh_token=\(enc(refreshToken))&grant_type=refresh_token"

        var req = URLRequest(url: URL(string: tokenURI)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.data(using: .utf8)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccess = json["access_token"] as? String else {
                logf("gcal refresh failed: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                return nil
            }
            let expiresIn = (json["expires_in"] as? Double) ?? 3600
            saveAccessToken(newAccess, expiryMs: Date().timeIntervalSince1970 * 1000 + expiresIn * 1000)
            logf("gcal token refreshed")
            return newAccess
        } catch {
            logf("gcal refresh error: \(error.localizedDescription)")
            return nil
        }
    }

    private static func saveAccessToken(_ access: String, expiryMs: Double) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: tokensPath)),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var normal = obj["normal"] as? [String: Any] else { return }
        normal["access_token"] = access
        normal["expiry_date"] = expiryMs
        obj["normal"] = normal
        if let out = try? JSONSerialization.data(withJSONObject: obj) {
            try? out.write(to: URL(fileURLWithPath: tokensPath))
        }
    }
}
