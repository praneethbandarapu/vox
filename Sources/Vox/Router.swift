import Foundation

// The router: a tool-calling agent loop over connected MCP tools, run on a fast
// model (Groq). Two-stage per step to keep each request tiny (free-tier token
// limits can't fit full tool schemas):
//   1) DECIDE: send a compact catalog (names + 1-line descriptions) -> pick a
//      tool, or answer, or ask a question.
//   2) FILL: send only the chosen tool's full schema -> produce arguments.
// User approves each tool call; results feed back until a final answer.

enum Router {
    private static let model = "llama-3.3-70b-versatile"
    private static let maxTurns = 6

    struct ProposedCall {
        let connector: String
        let tool: String
        let argsJSON: String
    }

    static func run(command: String,
                    confirm: @escaping (ProposedCall) async -> Bool,
                    onStatus: @escaping (String) -> Void) async -> String {
        guard let key = Keychain.get(account: groqAccount), !key.isEmpty else { return "No Groq key set." }

        let chosen = relevantConnectors(command)
        logf("[router] connectors: \(chosen.map { $0.id })")

        var catalog: [String] = []
        var route: [String: (connector: String, tool: String)] = [:]
        var schemas: [String: [String: Any]] = [:]
        for def in chosen {
            for t in await ConnectorManager.shared.toolDefs(def.id) {
                guard let name = t["name"] as? String else { continue }
                let fnName = "\(def.id)__\(name)"
                route[fnName] = (def.id, name)
                schemas[fnName] = (t["inputSchema"] as? [String: Any]) ?? ["type": "object", "properties": [:]]
                let desc = (t["description"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
                catalog.append("\(fnName): \(desc.prefix(90))")
            }
        }
        // Native fast-path tools for the chosen connectors (exact ops the MCP
        // servers can't do). Distinct name namespace; executed by local code.
        let chosenIds = Set(chosen.map { $0.id })
        for nt in NativeTools.all where chosenIds.contains(nt.connectorId) {
            route[nt.id] = ("native", nt.id)
            schemas[nt.id] = nt.inputSchema
            catalog.append("\(nt.id): \(nt.description.prefix(110))")
        }
        logf("[router] \(catalog.count) tools; sample: \(catalog.prefix(3).joined(separator: " | "))")
        onStatus("Thinking…")

        var scratch = ""   // running record of tool results
        var executed = Set<String>()
        for _ in 0..<maxTurns {
            guard let decision = await decide(key: key, command: command, catalog: catalog, scratch: scratch) else {
                return "Model error. See /tmp/vox.log."
            }
            logf("[router] decide: action=\(decision.action) tool=\(decision.tool) text=\(decision.text.prefix(120))")
            switch decision.action {
            case "answer", "question":
                return decision.text.isEmpty ? await finalize(key: key, command: command, scratch: scratch) : decision.text
            case "tool":
                guard let dest = route[decision.tool], let schema = schemas[decision.tool] else {
                    return decision.text.isEmpty ? "I couldn't map that to a tool." : decision.text
                }
                if executed.contains(decision.tool) {   // already ran it; conclude from results
                    return await finalize(key: key, command: command, scratch: scratch)
                }
                onStatus("Preparing \(dest.tool)…")
                let argsJSON = await fillArgs(key: key, command: command, scratch: scratch, fnName: decision.tool, schema: schema)
                let approved = await confirm(ProposedCall(connector: dest.connector, tool: dest.tool, argsJSON: argsJSON))
                var result = "The user declined this action."
                if approved {
                    onStatus("Running \(dest.tool)…")
                    let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
                    if dest.connector == "native" {
                        result = await (NativeTools.tool(dest.tool)?.handler(args) ?? "Unknown native tool.")
                    } else {
                        result = await ConnectorManager.shared.call(dest.connector, tool: dest.tool, arguments: args) ?? "Tool error."
                    }
                }
                executed.insert(decision.tool)
                scratch += "\n[\(decision.tool)] -> \(result.prefix(8000))"
                logf("[router] result[\(decision.tool)] approved=\(approved): \(result.prefix(200))")
            default:
                return "Unexpected router state."
            }
        }
        return await finalize(key: key, command: command, scratch: scratch)
    }

    // Produce a final answer from the tool results gathered so far.
    private static func finalize(key: String, command: String, scratch: String) async -> String {
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": "Answer the user's command in ONE short sentence using only the results below. An empty result means none (e.g. no events = 'nothing scheduled'). Do not ask questions or mention tools."],
                ["role": "user", "content": "Command: \(command)\n\nResults:\n\(scratch.isEmpty ? "(none)" : scratch)"]
            ]
        ]
        return (await post(key: key, body: body)?["content"] as? String) ?? "Done."
    }

    // MARK: stage 1 - decide

    private struct Decision { let action: String; let tool: String; let text: String }

    private static func decide(key: String, command: String, catalog: [String], scratch: String) async -> Decision? {
        let system = """
        You are Vox, a voice assistant that acts via connected tools. Decide the next step to fulfil the user's command.
        Respond with ONLY a JSON object: {"action":"tool"|"answer"|"question","tool":"<exact tool name or empty>","text":"<final answer or clarifying question, else empty>"}
        - "tool": call a tool from the list to make progress.
        - "answer": you have enough (from the work-so-far) to answer; put it in text.
        - "question": a required detail is missing and no tool can find it; ask ONE short question in text. Never guess names or emails.
        CRITICAL: If "Work so far" already contains a result for a tool, that IS your data, do NOT call that tool again. A successful but EMPTY result (e.g. totalCount 0, empty list) is a valid answer meaning "none" (e.g. no events = "nothing scheduled"). Once you have results, choose "answer".
        The user has a single Google account labelled "normal"; for calendar tools the account is "normal" and the calendar is "primary". NEVER ask which account, email, or calendar to use, just proceed with those.
        For "how many emails" / email count questions, use gmail_count (do NOT list emails to count them).
        """
        let user = """
        Command: \(command)

        Available tools:
        \(catalog.joined(separator: "\n"))

        Work so far:
        \(scratch.isEmpty ? "(none yet)" : scratch)
        """
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]]
        ]
        guard let msg = await post(key: key, body: body),
              let content = (msg["content"] as? String),
              let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Decision(
            action: (obj["action"] as? String) ?? "answer",
            tool: (obj["tool"] as? String) ?? "",
            text: (obj["text"] as? String) ?? ""
        )
    }

    // MARK: stage 2 - fill args (single tool, forced call)

    private static func fillArgs(key: String, command: String, scratch: String, fnName: String, schema: [String: Any]) async -> String {
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": ["name": fnName, "description": "", "parameters": schema]
        ]]
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": "Produce the correct arguments to call the tool for the user's command. Use only real values; never invent emails or names. For Google Calendar tools: the account is \"normal\" (set any account/account-name field to \"normal\") and calendarId is \"primary\". If the user asks how many, or for all/many items, set any maxResults/limit/count parameter to 100. Use the context if relevant."],
                ["role": "user", "content": "Command: \(command)\n\nContext:\n\(scratch.isEmpty ? "(none)" : scratch)"]
            ],
            "tools": tools,
            "tool_choice": ["type": "function", "function": ["name": fnName]]
        ]
        guard let msg = await post(key: key, body: body),
              let calls = msg["tool_calls"] as? [[String: Any]],
              let fn = calls.first?["function"] as? [String: Any],
              let args = fn["arguments"] as? String else { return "{}" }
        return args
    }

    // MARK: shared connector selection + HTTP

    private static func relevantConnectors(_ command: String) -> [ConnectorDef] {
        let c = command.lowercased()
        let keywords: [String: [String]] = [
            "gmail": ["email", "mail", "inbox", "unread", "draft", "reply", "gmail", "label", "archive", "sent", "compose"],
            "google-calendar": ["calendar", "schedule", "meeting", "event", "block", "invite", "appointment", "availab", "free time", "busy", "reschedule", "cancel", "agenda"],
            "slack": ["slack", "channel", "dm "]
        ]
        let configured = ConnectorManager.defs.filter { $0.isConfigured() }
        let matched = configured.filter { def in (keywords[def.id] ?? []).contains { c.contains($0) } }
        return matched.isEmpty ? configured : matched
    }

    private static func post(key: String, body: [String: Any]) async -> [String: Any]? {
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                logf("[router] groq HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let choices = json?["choices"] as? [[String: Any]]
            return choices?.first?["message"] as? [String: Any]
        } catch {
            logf("[router] groq error: \(error.localizedDescription)")
            return nil
        }
    }
}
