import Foundation

// Sends captured PCM16 audio to Deepgram's speech-to-text API and returns
// the transcript. The API key is read from the Keychain at call time.

enum Deepgram {
    static func transcribe(_ pcm16: Data) async -> String? {
        guard let key = Keychain.get(account: deepgramAccount), !key.isEmpty else {
            logf("Deepgram: no API key set")
            return nil
        }
        guard pcm16.count > 1600 else { // < ~0.05s of audio, skip
            logf("Deepgram: audio too short (\(pcm16.count) bytes)")
            return nil
        }

        var comps = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        comps.queryItems = [
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true")
        ]

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = pcm16

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                logf("Deepgram HTTP \(http.statusCode): \(body.prefix(300))")
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = json?["results"] as? [String: Any]
            let channels = results?["channels"] as? [[String: Any]]
            let alternatives = channels?.first?["alternatives"] as? [[String: Any]]
            let transcript = alternatives?.first?["transcript"] as? String
            logf("Deepgram transcript chars=\(transcript?.count ?? 0)")
            return transcript
        } catch {
            logf("Deepgram error: \(error.localizedDescription)")
            return nil
        }
    }
}
