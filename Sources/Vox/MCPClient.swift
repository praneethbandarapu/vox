import Foundation

// A minimal Model Context Protocol client over stdio. Spawns an MCP server once,
// performs the JSON-RPC handshake, and calls its tools. Build once, reuse for any
// MCP server (calendar, Slack, Gmail, ...). Keep the instance alive to stay warm.

final class MCPClient {
    private let proc = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var buffer = Data()
    private let lock = NSLock()

    enum MCPError: Error { case server(String), badResponse }

    // shellCommand is run via a login shell so PATH (nvm/npx) resolves.
    func start(shellCommand: String) throws {
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", shellCommand]
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let out = outPipe.fileHandleForReading
        out.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.onData(data) }
        }
        try proc.run()
        logf("[mcp] server started")
    }

    func stop() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        proc.terminate()
    }

    // MARK: Public MCP methods

    func initialize() async throws -> [String: Any] {
        let params: [String: Any] = [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "Vox", "version": "0.1"]
        ]
        let result = try await request("initialize", params)
        notify("notifications/initialized")
        return (result as? [String: Any]) ?? [:]
    }

    func listTools() async throws -> [[String: Any]] {
        let result = try await request("tools/list", [:])
        return ((result as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
    }

    // Returns the concatenated text content of the tool result.
    func callTool(_ name: String, arguments: [String: Any]) async throws -> String {
        let result = try await request("tools/call", ["name": name, "arguments": arguments])
        guard let dict = result as? [String: Any] else { throw MCPError.badResponse }
        let content = dict["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: JSON-RPC plumbing

    private func request(_ method: String, _ params: [String: Any]) async throws -> Any {
        lock.lock(); let id = nextId; nextId += 1; lock.unlock()
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: message)
        return try await withCheckedThrowingContinuation { cont in
            lock.lock(); pending[id] = cont; lock.unlock()
            var line = data
            line.append(0x0A)
            inPipe.fileHandleForWriting.write(line)
        }
    }

    private func notify(_ method: String, _ params: [String: Any] = [:]) {
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        inPipe.fileHandleForWriting.write(data)
    }

    private func onData(_ data: Data) {
        var lines: [Data] = []
        lock.lock()
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines { handleLine(line) }
    }

    private func handleLine(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        guard let id = obj["id"] as? Int else { return }   // ignore server-initiated messages
        lock.lock(); let cont = pending.removeValue(forKey: id); lock.unlock()
        guard let cont else { return }
        if let error = obj["error"] {
            cont.resume(throwing: MCPError.server(String(describing: error)))
        } else {
            cont.resume(returning: obj["result"] ?? [:])
        }
    }
}
