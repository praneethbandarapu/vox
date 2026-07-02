import Foundation

// Drives Claude Code headlessly (`claude -p --output-format stream-json`) on
// the user's subscription, no API key. Spawns it via a login shell so the
// nvm/PATH resolves `claude`, feeds the prompt over stdin, parses the streamed
// JSON events, captures the session id for --resume, and logs everything.

struct AgentEvent {
    enum Kind {
        case assistantText(String)
        case toolUse(name: String, input: String)
        case result(String)
    }
    let kind: Kind
}

final class ClaudeAgent {
    private(set) var sessionId: String?
    private var process: Process?

    func run(prompt: String,
             allowedTools: [String] = [],
             mcpConfigPath: String? = nil,
             strictMcp: Bool = false,
             onEvent: @escaping (AgentEvent) -> Void,
             completion: @escaping (String?) -> Void) {

        var command = "claude -p --output-format stream-json --verbose"
        if let sid = sessionId { command += " --resume \(sid)" }
        if let mcpConfigPath {
            command += " --mcp-config \"\(mcpConfigPath)\""
            if strictMcp { command += " --strict-mcp-config" }
        }
        if !allowedTools.isEmpty {
            command += " --allowedTools \"\(allowedTools.joined(separator: ","))\""
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", command]
        task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        var finalResult: String?
        var buffer = Data()
        let stdout = stdoutPipe.fileHandleForReading

        stdout.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
                self?.handleLine(line, onEvent: onEvent) { finalResult = $0 }
            }
        }

        task.terminationHandler = { _ in
            stdout.readabilityHandler = nil
            if let err = try? stderrPipe.fileHandleForReading.readToEnd(),
               let text = String(data: err, encoding: .utf8), !text.isEmpty {
                logf("[agent] stderr: \(text.prefix(300))")
            }
            DispatchQueue.main.async { completion(finalResult) }
        }

        do {
            try task.run()
            process = task
            if let data = (prompt + "\n").data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            stdinPipe.fileHandleForWriting.closeFile()
            logf("[agent] launched (resume=\(sessionId ?? "new"))")
        } catch {
            logf("[agent] launch error: \(error.localizedDescription)")
            completion(nil)
        }
    }

    private func handleLine(_ line: String,
                            onEvent: (AgentEvent) -> Void,
                            setResult: (String) -> Void) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "system":
            if let sid = json["session_id"] as? String { sessionId = sid }

        case "assistant":
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for block in content {
                let blockType = block["type"] as? String
                if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                    logf("[agent] assistant: \(text.prefix(200))")
                    onEvent(AgentEvent(kind: .assistantText(text)))
                } else if blockType == "tool_use", let name = block["name"] as? String {
                    let input = block["input"] as? [String: Any] ?? [:]
                    let inputStr = (try? JSONSerialization.data(withJSONObject: input))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    logf("[agent] tool_use: \(name) \(inputStr.prefix(200))")
                    onEvent(AgentEvent(kind: .toolUse(name: name, input: inputStr)))
                }
            }

        case "result":
            let result = json["result"] as? String ?? ""
            logf("[agent] result: \(result.prefix(200))")
            setResult(result)
            onEvent(AgentEvent(kind: .result(result)))

        default:
            break
        }
    }
}
