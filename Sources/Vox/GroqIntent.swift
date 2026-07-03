import Foundation

// Fast intent parser: turns a spoken command into a structured calendar action
// using Groq (open-source Llama). The heavy lifting is just understanding messy
// speech; execution is done natively by Vox afterwards.

struct CalendarIntent {
    let summary: String
    let startISO: String   // "yyyy-MM-dd'T'HH:mm:ss" (local to timeZone)
    let endISO: String
    let timeZone: String
    let attendees: [String]
}

enum ParsedIntent {
    case calendar(CalendarIntent)
    case other
    case failed
}

enum GroqIntent {
    private static let model = "llama-3.3-70b-versatile"

    static func parse(_ transcript: String) async -> ParsedIntent {
        guard let key = Keychain.get(account: groqAccount), !key.isEmpty else {
            logf("Groq: no API key set")
            return .failed
        }

        let tz = TimeZone.current.identifier
        let df = DateFormatter()
        df.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        let nowStr = df.string(from: Date())

        let system = """
        You convert a user's spoken command into a Google Calendar action.
        Current local date-time: \(nowStr). Timezone: \(tz).
        Output ONLY a JSON object, no prose, no code fences. Schema:
        {"kind":"calendar" or "other","summary":string,"start":"yyyy-MM-ddTHH:mm:ss","end":"yyyy-MM-ddTHH:mm:ss","timeZone":string,"attendees":[email strings]}
        Rules:
        - kind="calendar" for scheduling / blocking time / creating an event or meeting; otherwise kind="other".
        - Resolve relative dates/times ("tomorrow", "3pm") against the current local date-time. Default duration 30 minutes if unspecified.
        - NEVER invent an attendee email. Only include an attendee if the user explicitly spoke an email address. If only a name is given, leave attendees empty and put the name in the summary.
        - timeZone defaults to \(tz).
        """

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": transcript]
            ]
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return .failed }

        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                logf("Groq HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                return .failed
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let choices = json?["choices"] as? [[String: Any]]
            let content = (choices?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
            logf("Groq intent: \(content.prefix(200))")

            guard let obj = jsonObject(from: content) else { return .failed }
            let kind = obj["kind"] as? String ?? "other"
            guard kind == "calendar" else { return .other }

            let start = obj["start"] as? String ?? ""
            let end = obj["end"] as? String ?? ""
            guard !start.isEmpty, !end.isEmpty else { return .failed }
            return .calendar(CalendarIntent(
                summary: obj["summary"] as? String ?? "Event",
                startISO: start,
                endISO: end,
                timeZone: obj["timeZone"] as? String ?? tz,
                attendees: (obj["attendees"] as? [String]) ?? []
            ))
        } catch {
            logf("Groq error: \(error.localizedDescription)")
            return .failed
        }
    }

    private static func jsonObject(from string: String) -> [String: Any]? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
                 .replacingOccurrences(of: "```", with: "")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
