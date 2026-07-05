import Foundation

// Warm pool of MCP connectors. Each connector's server is spawned once via the
// MCP bridge and kept alive, so actions don't pay cold-start on every call.
// Adding a connector = one entry in `defs`.

struct ConnectorDef {
    let id: String
    let displayName: String
    let isConfigured: () -> Bool          // cheap check (no secret decryption)
    let makeCommand: () -> String?        // launch command incl. secrets; nil if unconfigured
}

final class ConnectorManager {
    static let shared = ConnectorManager()

    private var clients: [String: MCPClient] = [:]
    private let lock = NSLock()

    static var defs: [ConnectorDef] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            ConnectorDef(
                id: "google-calendar",
                displayName: "Google Calendar",
                isConfigured: { FileManager.default.fileExists(atPath: home + "/.vox/tokens.json") || TokenStore.exists("google") },
                makeCommand: {
                    let tokens = home + "/.vox/tokens.json"
                    guard FileManager.default.fileExists(atPath: tokens) else { return nil }
                    return "GOOGLE_OAUTH_CREDENTIALS=\"\(home)/.vox/gcp-oauth.keys.json\" GOOGLE_CALENDAR_MCP_TOKEN_PATH=\"\(tokens)\" exec npx @cocal/google-calendar-mcp"
                }
            ),
            ConnectorDef(
                id: "gmail",
                displayName: "Gmail",
                isConfigured: { FileManager.default.fileExists(atPath: home + "/.vox/gmail-credentials.json") },
                makeCommand: {
                    guard FileManager.default.fileExists(atPath: home + "/.vox/gmail-credentials.json") else { return nil }
                    return "GMAIL_OAUTH_PATH=\"\(home)/.vox/gcp-oauth.keys.json\" GMAIL_CREDENTIALS_PATH=\"\(home)/.vox/gmail-credentials.json\" exec npx @gongrzhe/server-gmail-autoauth-mcp"
                }
            ),
            ConnectorDef(
                id: "slack",
                displayName: "Slack",
                isConfigured: { Keychain.exists(account: slackAccount) },
                makeCommand: {
                    guard let token = Keychain.get(account: slackAccount), !token.isEmpty else { return nil }
                    return "SLACK_BOT_TOKEN=\"\(token)\" exec npx @slack/mcp-server"
                }
            )
        ]
    }

    static func def(_ id: String) -> ConnectorDef? { defs.first { $0.id == id } }

    // Returns a warm, initialized client, starting it on first use.
    func client(for id: String) async -> MCPClient? {
        lock.lock()
        if let existing = clients[id] { lock.unlock(); return existing }
        lock.unlock()

        guard let def = ConnectorManager.def(id), let cmd = def.makeCommand() else {
            logf("[conn] \(id) not configured")
            return nil
        }
        let client = MCPClient()
        do {
            try client.start(shellCommand: cmd)
            _ = try await client.initialize()
            lock.lock(); clients[id] = client; lock.unlock()
            logf("[conn] \(id) warm")
            return client
        } catch {
            logf("[conn] \(id) start failed: \(error)")
            return nil
        }
    }

    func listTools(_ id: String) async -> [String] {
        guard let client = await client(for: id) else { return [] }
        return ((try? await client.listTools()) ?? []).compactMap { $0["name"] as? String }
    }

    func call(_ id: String, tool: String, arguments: [String: Any]) async -> String? {
        guard let client = await client(for: id) else { return nil }
        do { return try await client.callTool(tool, arguments: arguments) }
        catch { logf("[conn] \(id).\(tool) failed: \(error)"); return nil }
    }

    func shutdown() {
        lock.lock(); let all = clients.values; clients.removeAll(); lock.unlock()
        for c in all { c.stop() }
    }
}
