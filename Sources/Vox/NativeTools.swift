import Foundation

// Native fast-path tools: exact operations the MCP servers can't do (or do
// badly). Surfaced to the Router exactly like MCP tools so voice still drives
// them, but executed by local code against the provider's REST API using the
// OAuth token we already hold. First case: an exact Gmail count. The Gmail MCP
// server has no count tool, so "how many unread" otherwise degrades to counting
// a truncated list. This asks the Gmail API directly and returns the number.

struct NativeTool {
    let id: String                          // router name, e.g. "gmail_count"
    let connectorId: String                 // for relevance filtering, e.g. "gmail"
    let description: String
    let inputSchema: [String: Any]
    let handler: ([String: Any]) async -> String
}

enum NativeTools {
    static let all: [NativeTool] = [
        NativeTool(
            id: "gmail_count",
            connectorId: "gmail",
            description: "Count emails matching a Gmail search query (e.g. is:unread, from:x). Use this for any 'how many emails' question instead of listing.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Gmail search query, e.g. 'is:unread' or 'from:foo@bar.com is:unread'"]
                ],
                "required": ["query"]
            ],
            handler: { args in await gmailCount((args["query"] as? String) ?? "is:unread") }
        )
    ]

    static func tool(_ id: String) -> NativeTool? { all.first { $0.id == id } }

    // NOTE: messages.list's resultSizeEstimate is a rough ESTIMATE and is badly
    // wrong on large mailboxes (observed 201 vs an actual 5433 unread). So:
    //  - single system-label queries (is:unread, in:inbox, …) -> labels.get,
    //    which carries the EXACT messagesTotal / messagesUnread.
    //  - anything else -> page messages.list and count real ids (bounded).
    private static let labelMap: [String: String] = [
        "is:unread": "UNREAD", "unread": "UNREAD",
        "in:inbox": "INBOX", "inbox": "INBOX",
        "is:starred": "STARRED", "starred": "STARRED",
        "is:important": "IMPORTANT", "important": "IMPORTANT",
        "in:sent": "SENT", "in:spam": "SPAM", "in:trash": "TRASH"
    ]

    private static func gmailCount(_ query: String) async -> String {
        guard let token = await GoogleAuth.accessToken() else { return "Not connected to Google." }
        let key = query.trimmingCharacters(in: .whitespaces).lowercased()

        if let labelId = labelMap[key], let json = await gmailGET(token, "labels/\(labelId)") {
            let count = (labelId == "UNREAD" || key.contains("unread"))
                ? (json["messagesUnread"] as? Int ?? json["messagesTotal"] as? Int ?? 0)
                : (json["messagesTotal"] as? Int ?? 0)
            logf("[native] gmail_count label=\(labelId) -> \(count) (exact)")
            return "{\"query\":\"\(query)\",\"count\":\(count),\"exact\":true}"
        }

        let (count, capped) = await pagedCount(token, query)
        logf("[native] gmail_count paged q=\"\(query)\" -> \(count) capped=\(capped)")
        return "{\"query\":\"\(query)\",\"count\":\(count),\"exact\":\(!capped)}"
    }

    // Count actual message ids for an arbitrary query, following nextPageToken.
    // Bounded so a huge result set can't stall the call; "capped" => report N+.
    private static func pagedCount(_ token: String, _ query: String) async -> (Int, Bool) {
        var total = 0, pages = 0
        var pageToken: String? = nil
        let maxPages = 6            // 6 * 500 = up to 3000 counted exactly
        repeat {
            var path = "messages?q=\(urlEncode(query))&maxResults=500"
            if let pt = pageToken { path += "&pageToken=\(urlEncode(pt))" }
            guard let json = await gmailGET(token, path) else { break }
            total += (json["messages"] as? [[String: Any]])?.count ?? 0
            pageToken = json["nextPageToken"] as? String
            pages += 1
        } while pageToken != nil && pages < maxPages
        return (total, pageToken != nil)
    }

    private static func gmailGET(_ token: String, _ path: String) async -> [String: Any]? {
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                logf("[native] gmail GET \(path.prefix(40)) HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(160) ?? "")")
                return nil
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            logf("[native] gmail GET error: \(error.localizedDescription)")
            return nil
        }
    }

    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: "+", with: "%2B") ?? s
    }
}
