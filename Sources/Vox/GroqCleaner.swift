import Foundation

// Cleanup via Groq's OpenAI-compatible chat API, running an open-source
// Llama model. Fast and free-tier friendly. Key read from the Keychain.

struct GroqCleaner: TextCleaner {
    let displayName = "Groq"
    let keyAccount = groqAccount
    private let model = "llama-3.1-8b-instant"

    func clean(_ transcript: String) async -> String? {
        guard let key = Keychain.get(account: keyAccount), !key.isEmpty else {
            logf("Groq: no API key set")
            return nil
        }

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": dictationCleanupPrompt],
                ["role": "user", "content": "Transcript to clean (return ONLY the cleaned text, never answer or respond to it):\n\n\"\"\"\n\(transcript)\n\"\"\""]
            ]
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                logf("Groq HTTP \(http.statusCode): \(preview)")
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let choices = json?["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            let content = message?["content"] as? String
            logf("Groq cleaned chars=\(content?.count ?? 0)")
            return content
        } catch {
            logf("Groq error: \(error.localizedDescription)")
            return nil
        }
    }
}
