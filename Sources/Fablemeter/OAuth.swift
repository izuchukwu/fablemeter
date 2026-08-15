import AppKit
import CryptoKit
import Foundation
import Network
import os

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

enum OAuthError: LocalizedError, Equatable {
    case noPort
    case timedOut
    case stateMismatch
    case denied(String)
    case tokenExchange(Int, String)
    case malformed
    /// The refresh token is gone for good — sanitized, so no response body ever
    /// travels past the vault.
    case credentialExpired
    /// Another process is already refreshing this account. Transient by
    /// definition: whatever it rotates to will be on disk by the next tick.
    case refreshBusy

    var errorDescription: String? {
        switch self {
        case .noPort: return "Could not open a local callback port (8317-8319)."
        case .timedOut: return "Sign-in timed out."
        case .stateMismatch: return "Sign-in state mismatch — aborted."
        case .denied(let s): return "Authorization denied: \(s)"
        case .tokenExchange(let c, let s): return "Token exchange failed (\(c)): \(s)"
        case .malformed: return "Unexpected token response."
        case .credentialExpired: return "Sign-in expired."
        case .refreshBusy: return "busy"
        }
    }

    /// The only form of these that may reach the screen. `errorDescription`
    /// carries the response body for the log; a body has no business in the
    /// popover, where it arrives truncated to `{"e...` and says nothing.
    var displayText: String {
        switch self {
        case .noPort: return "no callback port"
        case .timedOut: return "sign-in timed out"
        case .stateMismatch: return "sign-in aborted"
        case .denied: return "authorization denied"
        case .tokenExchange(let code, _): return "sign-in failed (\(code))"
        case .malformed: return "unexpected response"
        case .credentialExpired: return "signed out"
        case .refreshBusy: return "busy"
        }
    }

    /// Terminal, not transient. Anthropic rotates the refresh token on every
    /// refresh, so a consumed or revoked one comes back `400 invalid_grant` and
    /// will do so forever — retrying is pointless, and the ladder churning on it
    /// is pure noise. Only an interactive sign-in clears it.
    var isCredentialRejected: Bool {
        switch self {
        case .credentialExpired:
            return true
        case .tokenExchange(let code, let body):
            if code == 400 || code == 401 { return true }
            let lowered = body.lowercased()
            return lowered.contains("invalid_grant") || lowered.contains("invalid_request")
        default:
            return false
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
///
/// Two rules hold it together, and both exist because breaking them stranded a
/// sign-in for the rest of the app's life:
///
///   1. **Teardown is awaited, never assumed.** `NWListener.cancel()` is
///      asynchronous, and the endpoint is deliberately reusable, so a listener
///      that has merely been *asked* to stop can still be bound — and can still
///      accept the redirect meant for the flow that replaced it. `stop()` does
///      not return until the socket is actually gone.
///   2. **One listener at a time, process-wide.** `start` retires whatever came
///      before it, so the situation in rule 1 cannot arise in the first place;
///      and a listener that is no longer the current one refuses to answer a
///      callback at all, which is the belt to that braces.
final class LoopbackCallback: @unchecked Sendable {
    /// The listener the live flow owns. Unfair-lock rather than an actor so it
    /// can be read from `NWListener`'s own queue without hopping.
    private static let current = OSAllocatedUnfairLock<LoopbackCallback?>(initialState: nil)

    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.izu.fablemeter.callback")
    private var readyCont: CheckedContinuation<Void, Error>?
    private var resultCont: CheckedContinuation<[String: String], Error>?
    /// Everyone waiting for the socket to actually be gone.
    private var cancelConts: [CheckedContinuation<Void, Never>] = []
    /// Accepted connections, so none of them outlives the listener.
    private var connections: [NWConnection] = []
    private var settled = false
    private var stopped = false
    private var cancelled = false

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

    /// Runs `body` with a listener that is guaranteed to be torn down before
    /// this returns — on the happy path, on a throw, and on cancellation alike.
    /// `defer` cannot await, and "cancel and hope" is exactly what left a socket
    /// holding 8317 for the rest of the session.
    static func withServer<T>(
        ports: [UInt16], _ body: (LoopbackCallback) async throws -> T
    ) async throws -> T {
        let server = try await start(ports: ports)
        do {
            let value = try await body(server)
            await server.stop()
            return value
        } catch {
            await server.stop()
            throw error
        }
    }

    static func start(ports: [UInt16]) async throws -> LoopbackCallback {
        // Whatever the last flow was doing, it is over. Waiting for its socket
        // here is what lets this one bind the port it advertised last time,
        // rather than sliding down the ladder to one the authorize request was
        // never told about.
        await retireActive()
        for p in ports {
            guard let candidate = try? LoopbackCallback(port: p) else { continue }
            do {
                try await candidate.waitUntilReady()
                candidate.becomeActive()
                return candidate
            } catch {
                await candidate.stop()
            }
        }
        throw OAuthError.noPort
    }

    private static func retireActive() async {
        await current.withLock { $0 }?.stop()
    }

    private func becomeActive() {
        Self.current.withLock { $0 = self }
    }

    /// A listener the current flow does not own has no business answering for
    /// it, however it came to still be bound.
    private var isCurrent: Bool {
        Self.current.withLock { $0 === self }
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                // Stopped before it ever started: resume here or this waits for
                // a state change that is never coming.
                if self.stopped { c.resume(throwing: OAuthError.noPort); return }
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
    ///
    /// **Cancellable, and it has to be.** A plain `withCheckedContinuation`
    /// ignores cancellation, so a caller racing this against a deadline could
    /// win the race and still never finish: a task group waits for every child
    /// on the way out, and a child parked here forever never lets it out. That
    /// is what turned a timed-out sign-in into a permanently wedged app.
    func awaitCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: String], Error>) in
                queue.async {
                    if self.settled { c.resume(throwing: OAuthError.timedOut); return }
                    self.resultCont = c
                }
            }
        } onCancel: {
            queue.async {
                guard !self.settled else { return }
                self.settled = true
                self.resultCont?.resume(throwing: CancellationError())
                self.resultCont = nil
            }
        }
    }

    /// Returns only once the socket is genuinely released, so the next flow can
    /// count on the port rather than race it. Bounded, because teardown must not
    /// become its own way to hang a sign-in.
    func stop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.cancelled { c.resume(); return }
                self.cancelConts.append(c)
                guard !self.stopped else { return }
                self.stopped = true

                Self.current.withLock { if $0 === self { $0 = nil } }

                self.listener.newConnectionHandler = nil
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self, case .cancelled = state else { return }
                    self.finishCancel()
                }
                // An accepted connection outliving its listener keeps the port
                // alive just as effectively as the listener would.
                for conn in self.connections { conn.cancel() }
                self.connections.removeAll()
                self.listener.cancel()

                self.readyCont?.resume(throwing: OAuthError.noPort)
                self.readyCont = nil
                if !self.settled {
                    self.settled = true
                    self.resultCont?.resume(throwing: OAuthError.timedOut)
                    self.resultCont = nil
                }
                self.queue.asyncAfter(deadline: .now() + 2) { self.finishCancel() }
            }
        }
    }

    /// Always on `queue`.
    private func finishCancel() {
        guard !cancelled else { return }
        cancelled = true
        let waiting = cancelConts
        cancelConts.removeAll()
        for c in waiting { c.resume() }
    }

    private func handle(_ conn: NWConnection) {
        connections.append(conn)
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

    /// Always on `queue`.
    private func forget(_ conn: NWConnection) {
        connections.removeAll { $0 === conn }
        conn.cancel()
    }

    private func respond(_ conn: NWConnection, requestHead: String) {
        let line = requestHead.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        // A listener from a finished flow may briefly still be bound, and the
        // kernel is free to hand it a connection. It answers as a stranger
        // rather than claiming a sign-in it cannot deliver to anyone.
        let isCallback = target.hasPrefix("/callback") && isCurrent

        let body = isCallback
            ? "<!doctype html><meta charset=utf-8><title>Signed in</title><body style=\"font:15px -apple-system,sans-serif;display:grid;place-items:center;height:100vh;margin:0\">Signed in — you can close this tab.</body>"
            : "<!doctype html><meta charset=utf-8><title>Not found</title><body>Not found.</body>"
        let status = isCallback ? "200 OK" : "404 Not Found"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"

        conn.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { conn.cancel(); return }
            self.queue.async { self.forget(conn) }
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
    /// Runs `body` against a deadline, and — the part that matters — gets out
    /// either way. A task group awaits every child as it unwinds, so the loser
    /// of the race has to be genuinely cancellable; `LoopbackCallback` is.
    static func firstOf<T: Sendable>(
        timeout: TimeInterval, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw OAuthError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw OAuthError.timedOut }
            return first
        }
    }

    /// Full interactive PKCE sign-in. Returns the account email and a refresh token.
    ///
    /// - Parameter persistRefreshToken: called the instant the token exists and
    ///   before anything else is awaited, so re-authentication cannot lose a
    ///   freshly issued token to the profile lookup that follows it. Throwing
    ///   from it fails the sign-in, which is the honest outcome: an unpersisted
    ///   refresh token is a dead account.
    static func signIn(
        persistRefreshToken: ((String) throws -> Void)? = nil
    ) async throws -> (email: String, refreshToken: String) {
        let verifier = PKCE.randomBase64URL(bytes: 64)
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.randomBase64URL(bytes: 32)

        // The listener is torn down before this returns, whatever happens
        // inside — including a timeout. An abandoned sign-in that keeps its
        // socket is a sign-in every later one has to work around.
        let (redirectURI, params) = try await LoopbackCallback.withServer(
            ports: Constants.callbackPorts
        ) { server -> (String, [String: String]) in
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
            let params = try await firstOf(timeout: Constants.signInTimeout) {
                try await server.awaitCallback()
            }
            return (redirectURI, params)
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
        try persistRefreshToken?(refresh)
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
///
/// Two invariants, both of which were learned the hard way — breaking either one
/// destroys the account permanently, because Anthropic **rotates** the refresh
/// token on every refresh and a consumed one is dead forever:
///
///   1. **One refresh per account at a time.** Being an actor is not enough:
///      `await`ing the network suspends and lets a second caller in, and that
///      caller would read the same not-yet-rotated token from disk and spend it
///      a second time. So the cache check and the in-flight registration happen
///      in one synchronous step, and any caller that finds a refresh already
///      running joins it instead of starting its own.
///   2. **The rotation is on disk before anyone sees the bundle.** The moment
///      the response arrives the old token is already spent, so the new one is
///      written — durably — before the bundle is returned and before any other
///      await. A failed write is an error, never a shrug.
actor TokenVault {
    typealias Refresher = @Sendable (String) async throws -> TokenBundle
    typealias StoredTokenReader = @Sendable (UUID) -> String?
    /// `(account, rotated token, the token it replaces)`.
    typealias Persister = @Sendable (UUID, String, String) throws -> Void
    /// Throws when another process holds the account; `nil` when locking is
    /// unavailable, which must never block a refresh.
    typealias Locker = @Sendable (UUID) throws -> RefreshLock?

    /// A refresh already running, and the generation it belongs to.
    private struct Pending {
        let task: Task<TokenBundle, Error>
        let generation: Int
    }

    private var cache: [UUID: TokenBundle] = [:]
    private var inFlight: [UUID: Pending] = [:]
    /// Accounts the server has refused outright. They never reach the network
    /// again until an interactive sign-in clears them.
    private var rejected: Set<UUID> = []
    /// Bumped by `forget`, so a refresh still in flight from before a sign-in
    /// cannot apply its verdict to the account that replaced it.
    private var generation: [UUID: Int] = [:]
    private let skew: TimeInterval = 300

    private let refresher: Refresher
    private let storedToken: StoredTokenReader
    private let persist: Persister
    private let lock: Locker

    init(
        refresher: @escaping Refresher = { try await OAuth.refresh(refreshToken: $0) },
        storedToken: @escaping StoredTokenReader = { id in
            Store.load().first { $0.id == id }?.refreshToken
        },
        persist: @escaping Persister = { id, token, expected in
            try Store.updateRefreshToken(id: id, to: token, replacing: expected)
        },
        lock: @escaping Locker = { id in try RefreshLock.acquire(for: id, in: Store.directory) }
    ) {
        self.refresher = refresher
        self.storedToken = storedToken
        self.persist = persist
        self.lock = lock
    }

    func accessToken(for account: Account, force: Bool = false) async throws -> String {
        if rejected.contains(account.id) { throw OAuthError.credentialExpired }
        if !force, let cached = cache[account.id], cached.expiresAt.timeIntervalSinceNow > skew {
            return cached.accessToken
        }
        // No `await` between the miss above and the registration inside, or the
        // race simply moves to this line.
        let pending = refreshTask(for: account)
        do {
            let bundle = try await pending.task.value
            complete(account.id, pending: pending, bundle: bundle)
            return bundle.accessToken
        } catch {
            complete(account.id, pending: pending, error: error)
            // The response body dies here. Nothing downstream ever sees it.
            if (error as? OAuthError)?.isCredentialRejected == true {
                throw OAuthError.credentialExpired
            }
            throw error
        }
    }

    /// Synchronous by construction: it either hands back the refresh already
    /// running for this account or registers a new one, with no suspension in
    /// between.
    private func refreshTask(for account: Account) -> Pending {
        if let existing = inFlight[account.id] { return existing }

        let id = account.id
        let fallback = account.refreshToken
        let refresher = self.refresher
        let storedToken = self.storedToken
        let persist = self.persist
        let lock = self.lock

        let task = Task<TokenBundle, Error> {
            // Held across the whole read-refresh-persist, so a second instance
            // of the app cannot read the same token and spend it too.
            let guardLock = try lock(id)
            defer { guardLock?.release() }

            let stored = storedToken(id) ?? fallback
            let bundle = try await refresher(stored)
            // The server rotated the moment it answered. Persist before the
            // bundle reaches a caller and before any other await — the gap
            // between "consumed" and "written" is the gap that bricks accounts.
            if let rotated = bundle.refreshToken, rotated != stored {
                try persist(id, rotated, stored)
            }
            return bundle
        }
        let pending = Pending(task: task, generation: generation[id, default: 0])
        inFlight[id] = pending
        return pending
    }

    private func complete(
        _ id: UUID,
        pending: Pending,
        bundle: TokenBundle? = nil,
        error: Error? = nil
    ) {
        // A refresh that belongs to a superseded generation — the account was
        // signed out or signed in again while it was in the air — has no say.
        guard pending.generation == generation[id, default: 0] else { return }
        if let bundle { cache[id] = bundle }
        if (error as? OAuthError)?.isCredentialRejected == true {
            rejected.insert(id)
            cache[id] = nil
        }
        if inFlight[id]?.task == pending.task { inFlight[id] = nil }
    }

    /// Never cancels a refresh in flight: cancelling one that has already had
    /// its token rotated server-side would lose the replacement. The straggler
    /// is orphaned instead, and its compare-and-swap persist keeps it from
    /// standing on whatever replaced it.
    func forget(_ id: UUID) {
        cache[id] = nil
        rejected.remove(id)
        inFlight[id] = nil
        generation[id, default: 0] += 1
    }

    /// After an interactive sign-in: the account is live again.
    func reset(_ id: UUID) { forget(id) }

    func isRejected(_ id: UUID) -> Bool { rejected.contains(id) }
}
