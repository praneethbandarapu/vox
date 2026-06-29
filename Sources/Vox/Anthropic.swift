import Foundation

// Post-processes a raw dictation transcript with Claude: fixes punctuation,
// capitalization, and removes filler words, without changing meaning.
// Uses Haiku for low latency. Key read from the Keychain at call time.

struct AnthropicCleaner: TextCleaner {
    let displayName = "Anthropic"
    let keyAccount = anthropicAccount
    private let model = "claude-haiku-4-5-20251001"
    private let systemPrompt = dictationCleanupPrompt

    func clean(_ transcript: String) async -> String? {
        guard let key = Keychain.get(account: anthropicAccount), !key.isEmpty else {
            logf("Anthropic: no API key set")
            return nil
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [["role": "user", "content": transcript]]
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                logf("Anthropic HTTP \(http.statusCode): \(preview)")
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let content = json?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String
            logf("Anthropic cleaned chars=\(text?.count ?? 0)")
            return text
        } catch {
            logf("Anthropic error: \(error.localizedDescription)")
            return nil
        }
    }
}
