import Foundation

// Live streaming speech-to-text over Deepgram's websocket. Audio is sent in
// real time while the user holds the key, so on release the transcript is
// already (almost) ready. Much lower perceived latency than batch upload.

final class DeepgramStream {
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var finals: [String] = []
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private var finished = false

    func start() {
        guard let key = Keychain.get(account: deepgramAccount), !key.isEmpty else {
            logf("DeepgramStream: no API key")
            return
        }
        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        comps.queryItems = [
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "interim_results", value: "false")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
        logf("DeepgramStream opened")
    }

    func send(_ pcm: Data) {
        task?.send(.data(pcm)) { error in
            if let error { logf("DeepgramStream send error: \(error.localizedDescription)") }
        }
    }

    // Tell Deepgram to flush, then wait for the final transcript.
    func finish() async -> String {
        task?.send(.string("{\"type\":\"CloseStream\"}")) { _ in }
        return await withCheckedContinuation { cont in
            lock.lock()
            if finished {
                lock.unlock()
                cont.resume(returning: joinedFinals())
                return
            }
            continuation = cont
            lock.unlock()
            // Safety net: don't hang if the socket never closes cleanly.
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.complete()
            }
        }
    }

    // MARK: Internals

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                // Expected when the socket closes after we send CloseStream.
                self.complete()
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = json["channel"] as? [String: Any],
              let alts = channel["alternatives"] as? [[String: Any]],
              let transcript = alts.first?["transcript"] as? String,
              !transcript.isEmpty else { return }
        let isFinal = (json["is_final"] as? Bool) ?? false
        if isFinal {
            lock.lock(); finals.append(transcript); lock.unlock()
        }
    }

    private func joinedFinals() -> String {
        lock.lock(); let s = finals.joined(separator: " "); lock.unlock()
        return s
    }

    private func complete() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        cont?.resume(returning: joinedFinals())
    }
}
