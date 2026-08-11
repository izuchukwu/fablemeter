import AppKit
import CryptoKit
import Foundation
import Network

enum Constants {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    static let profileURL = "https://api.anthropic.com/api/oauth/profile"
    static let betaVersion = "oauth-2025-04-20"

    /// Read-only. Deliberately does NOT request `user:inference`.
    static let scope = "user:profile"
    /// Fallback if the narrow scope is ever rejected by /api/oauth/usage.
    static let broadScope = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    static let callbackPorts: [UInt16] = [8317, 8318, 8319]
    static let signInTimeout: TimeInterval = 300
}

enum OAuthError: LocalizedError {
    case noPort
    case timedOut
    case stateMismatch
    case denied(String)
    case tokenExchange(Int, String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .noPort: return "Could not open a local callback port (8317-8319)."
        case .timedOut: return "Sign-in timed out."
        case .stateMismatch: return "Sign-in state mismatch — aborted."
        case .denied(let s): return "Authorization denied: \(s)"
        case .tokenExchange(let c, let s): return "Token exchange failed (\(c)): \(s)"
        case .malformed: return "Unexpected token response."
        }
    }
}

// MARK: - PKCE

enum PKCE {
    static func randomBase64URL(bytes count: Int) -> String {
        var buf = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &buf) != errSecSuccess {
            for i in 0..<count { buf[i] = UInt8.random(in: 0...255) }
        }
        return base64URL(Data(buf))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback callback server

/// Single-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect.
final class LoopbackCallback: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.izu.claudeusagebar.callback")
    private var readyCont: CheckedContinuation<Void, Error>?
    private var resultCont: CheckedContinuation<[String: String], Error>?
    private var settled = false
    private var stopped = false

    private init(port: UInt16) throws {
        self.port = port
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw OAuthError.noPort }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        self.listener = try NWListener(using: params)
    }

    static func start(ports: [UInt16]) async throws -> LoopbackCallback {
        for p in ports {
            guard let candidate = try? LoopbackCallback(port: p) else { continue }
            do {
                try await candidate.waitUntilReady()
                return candidate
            } catch {
                candidate.stop()
            }
        }
        throw OAuthError.noPort
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                self.readyCont = c
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.readyCont?.resume(); self.readyCont = nil
                    case .failed(let err), .waiting(let err):
                        self.readyCont?.resume(throwing: err); self.readyCont = nil
                    case .cancelled:
                        self.readyCont?.resume(throwing: OAuthError.noPort); self.readyCont = nil
                    default:
                        break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] conn in
                    self?.handle(conn)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    /// Resolves with the query parameters of the first `/callback` request.
    func awaitCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: String], Error>) in
            queue.async {
                if self.settled { c.resume(throwing: OAuthError.timedOut); return }
                self.resultCont = c
            }
        }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.listener.stateUpdateHandler = nil
            self.listener.newConnectionHandler = nil
            self.listener.cancel()
            if !self.settled {
                self.settled = true
                self.resultCont?.resume(throwing: OAuthError.timedOut)
                self.resultCont = nil
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isDone, _ in
                guard let self else { return }
                if let data { buffer.append(data) }
                let text = String(decoding: buffer, as: UTF8.self)
                if text.contains("\r\n\r\n") || isDone {
                    self.respond(conn, requestHead: text)
                } else if !isDone {
                    receive()
                }
            }
        }
        receive()
    }

    private func respond(_ conn: NWConnection, requestHead: String) {
        let line = requestHead.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let isCallback = target.hasPrefix("/callback")

        let body = isCallback
            ? "<!doctype html><meta charset=utf-8><title>Signed in</title><body style=\"font:15px -apple-system,sans-serif;display:grid;place-items:center;height:100vh;margin:0\">Signed in — you can close this tab.</body>"
            : "<!doctype html><meta charset=utf-8><title>Not found</title><body>Not found.</body>"
        let status = isCallback ? "200 OK" : "404 Not Found"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"

        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })

        guard isCallback, !settled else { return }
        settled = true
        var params: [String: String] = [:]
        if let comps = URLComponents(string: "http://localhost" + target) {
            for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
        }
        resultCont?.resume(returning: params)
        resultCont = nil
    }
}

// MARK: - Tokens

struct TokenBundle {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var email: String?
}

enum OAuth {
    /// Full interactive PKCE sign-in. Returns the account email and a refresh token.
    static func signIn() async throws -> (email: String, refreshToken: String) {
        let verifier = PKCE.randomBase64URL(bytes: 64)
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.randomBase64URL(bytes: 32)

        let server = try await LoopbackCallback.start(ports: Constants.callbackPorts)
        defer { server.stop() }

        let redirectURI = "http://localhost:\(server.port)/callback"
        var comps = URLComponents(string: Constants.authorizeURL)!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Constants.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Constants.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authURL = comps.url else { throw OAuthError.malformed }
        NSWorkspace.shared.open(authURL)

        let params = try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await server.awaitCallback() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Constants.signInTimeout * 1_000_000_000))
                throw OAuthError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw OAuthError.timedOut }
            return first
        }

        if let err = params["error"] {
            throw OAuthError.denied(params["error_description"] ?? err)
        }
        guard var code = params["code"], !code.isEmpty else { throw OAuthError.malformed }

        // The authorization code can arrive as `code#state`.
        var returnedState = params["state"]
        if let hash = code.firstIndex(of: "#") {
            returnedState = String(code[code.index(after: hash)...])
            code = String(code[code.startIndex..<hash])
        }
        guard returnedState == state else { throw OAuthError.stateMismatch }

        let bundle = try await exchange(code: code, verifier: verifier, redirectURI: redirectURI, state: state)
        guard let refresh = bundle.refreshToken else { throw OAuthError.malformed }
        var email = bundle.email
        if email == nil || email?.isEmpty == true {
            email = try? await fetchProfileEmail(accessToken: bundle.accessToken)
        }
        return (email ?? "Claude account", refresh)
    }

    private static func exchange(code: String, verifier: String, redirectURI: String, state: String) async throws -> TokenBundle {
        try await post(body: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": Constants.clientID,
            "code_verifier": verifier,
            "state": state
        ])
    }

    static func refresh(refreshToken: String) async throws -> TokenBundle {
        try await post(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Constants.clientID
        ])
    }

    private static func post(body: [String: String]) async throws -> TokenBundle {
        var req = URLRequest(url: URL(string: Constants.tokenURL)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Constants.betaVersion, forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let detail = String(decoding: data.prefix(200), as: UTF8.self)
            throw OAuthError.tokenExchange(code, detail)
        }
        guard let access = json["access_token"] as? String else { throw OAuthError.malformed }
        let expiresIn = JSONScalar.number(json["expires_in"]) ?? 3600
        let account = json["account"] as? [String: Any]
        let email = (account?["email_address"] as? String) ?? (account?["email"] as? String)
        return TokenBundle(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: Date().addingTimeInterval(expiresIn),
            email: email
        )
    }

    static func fetchProfileEmail(accessToken: String) async throws -> String? {
        var req = URLRequest(url: URL(string: Constants.profileURL)!)
        req.timeoutInterval = 10
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(Constants.betaVersion, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let account = json["account"] as? [String: Any]
        return (account?["email"] as? String) ?? (account?["email_address"] as? String)
    }
}

// MARK: - Access token cache

/// Holds access tokens in memory only, refreshing them 5 minutes before expiry
/// and persisting rotated refresh tokens straight away.
actor TokenVault {
    private var cache: [UUID: TokenBundle] = [:]
    private let skew: TimeInterval = 300

    func accessToken(for account: Account, force: Bool = false) async throws -> String {
        if !force, let cached = cache[account.id], cached.expiresAt.timeIntervalSinceNow > skew {
            return cached.accessToken
        }
        let stored = Store.load().first { $0.id == account.id }?.refreshToken ?? account.refreshToken
        let bundle = try await OAuth.refresh(refreshToken: stored)
        cache[account.id] = bundle
        if let rotated = bundle.refreshToken, rotated != stored {
            Store.updateRefreshToken(id: account.id, to: rotated)
        }
        return bundle.accessToken
    }

    func forget(_ id: UUID) {
        cache[id] = nil
    }
}
