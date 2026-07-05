import Foundation
import Darwin
import CryptoKit
import AppKit

// Generic OAuth 2.0 authorization-code + PKCE flow with a loopback redirect.
// Uses a plain POSIX socket on 127.0.0.1 to capture the redirect (no Network
// framework quirks). Reused per provider.

struct OAuthConfig {
    let name: String
    let authEndpoint: String
    let tokenEndpoint: String
    let clientID: String
    let clientSecret: String?
    let scopes: [String]
    let extraAuthParams: [String: String]   // e.g. Google: access_type=offline, prompt=consent
}

struct OAuthTokens {
    let access: String
    let refresh: String?
    let expiryMs: Double
}

enum OAuthFlow {
    static func authorize(_ config: OAuthConfig) async -> OAuthTokens? {
        let verifier = randomString(64)
        let challenge = codeChallenge(verifier)
        let state = randomString(24)

        guard let (fd, port) = startLoopbackSocket() else {
            logf("[oauth] could not open loopback socket")
            return nil
        }
        let redirect = "http://127.0.0.1:\(port)/callback"

        var comps = URLComponents(string: config.authEndpoint)!
        var items = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        for (k, v) in config.extraAuthParams { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items

        let code: String? = await withCheckedContinuation { cont in
            var resumed = false
            let finish: (String?) -> Void = { value in
                if !resumed { resumed = true; cont.resume(returning: value) }
            }
            acceptCode(fd: fd, expectedState: state, completion: finish)
            if let url = comps.url {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                logf("[oauth] opened browser for \(config.name) (port \(port))")
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 180) { finish(nil) }
        }
        close(fd)

        guard let code else { logf("[oauth] no code (timeout or denied)"); return nil }
        return await exchange(config, code: code, verifier: verifier, redirect: redirect)
    }

    // MARK: POSIX loopback listener

    private static func startLoopbackSocket() -> (fd: Int32, port: UInt16)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { logf("[oauth] socket() errno=\(errno)"); return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                       // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindOK = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { logf("[oauth] bind errno=\(errno)"); close(fd); return nil }
        guard listen(fd, 1) == 0 else { logf("[oauth] listen errno=\(errno)"); close(fd); return nil }

        var name = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOK = withUnsafeMutablePointer(to: &name) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard nameOK == 0 else { close(fd); return nil }
        return (fd, UInt16(bigEndian: name.sin_port))
    }

    private static func acceptCode(fd: Int32, expectedState: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global().async {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { completion(nil); return }
            var buf = [UInt8](repeating: 0, count: 16384)
            let n = read(client, &buf, buf.count)
            var code: String? = nil
            if n > 0 {
                let req = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
                if queryValue(req, "state") == expectedState { code = queryValue(req, "code") }
            }
            let ok = code != nil
            let body = ok
                ? "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>Connected.</h2><p>You can close this tab.</p></body></html>"
                : "<html><body><h2>Authorization failed.</h2></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            let out = Array(resp.utf8)
            _ = out.withUnsafeBytes { write(client, $0.baseAddress, out.count) }
            close(client)
            completion(code)
        }
    }

    private static func queryValue(_ request: String, _ key: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: "http://localhost\(parts[1])") else { return nil }
        return comps.queryItems?.first { $0.name == key }?.value
    }

    // MARK: token exchange

    private static func exchange(_ config: OAuthConfig, code: String, verifier: String, redirect: String) async -> OAuthTokens? {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        var body = "grant_type=authorization_code&code=\(enc(code))&redirect_uri=\(enc(redirect))&client_id=\(enc(config.clientID))&code_verifier=\(enc(verifier))"
        if let secret = config.clientSecret { body += "&client_secret=\(enc(secret))" }

        var req = URLRequest(url: URL(string: config.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String else {
                logf("[oauth] exchange failed: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                return nil
            }
            let refresh = json["refresh_token"] as? String
            let expiresIn = (json["expires_in"] as? Double) ?? 3600
            logf("[oauth] \(config.name) token obtained")
            return OAuthTokens(access: access, refresh: refresh, expiryMs: Date().timeIntervalSince1970 * 1000 + expiresIn * 1000)
        } catch {
            logf("[oauth] exchange error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: PKCE helpers

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    private static func codeChallenge(_ verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
