import AppKit
@testable import FablemeterCore
import Foundation
import Network
import os

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
    /// What the success page says — sign-in and connect finish differently.
    private let successText: String
    /// When set, a `/callback` whose `state` query does not match is answered
    /// as a stranger and the flow keeps waiting. The port scheme is public
    /// (the repo is), and any web page can fire requests at 127.0.0.1, so a
    /// guessed callback must not be able to consume the attempt — refusal
    /// happens here at the socket, not after teardown.
    private let expectedState: String?
    /// Pinned so the selftest can refuse a drift to "any interface": binding
    /// loopback only is the other half of the handoff's security story.
    let requiredHost: NWEndpoint.Host = .ipv4(.loopback)
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

    private init(port: UInt16, successText: String, expectedState: String?) throws {
        self.port = port
        self.successText = successText
        self.expectedState = expectedState
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw OAuthError.noPort }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        params.requiredLocalEndpoint = .hostPort(host: requiredHost, port: nwPort)
        self.listener = try NWListener(using: params)
    }

    /// The port actually bound. For the fixed sign-in ports this is `port`;
    /// for an ephemeral bind (`ports: [0]`, the connect flow) it is whatever
    /// the kernel assigned, and it is what the browser must be told.
    var boundPort: UInt16 { listener.port?.rawValue ?? port }

    /// Runs `body` with a listener that is guaranteed to be torn down before
    /// this returns — on the happy path, on a throw, and on cancellation alike.
    /// `defer` cannot await, and "cancel and hope" is exactly what left a socket
    /// holding 8317 for the rest of the session.
    static func withServer<T>(
        ports: [UInt16],
        successText: String = "Signed in — you can close this tab.",
        expectedState: String? = nil,
        _ body: (LoopbackCallback) async throws -> T
    ) async throws -> T {
        let server = try await start(
            ports: ports, successText: successText, expectedState: expectedState
        )
        do {
            let value = try await body(server)
            await server.stop()
            return value
        } catch {
            await server.stop()
            throw error
        }
    }

    static func start(
        ports: [UInt16],
        successText: String = "Signed in — you can close this tab.",
        expectedState: String? = nil
    ) async throws -> LoopbackCallback {
        // Whatever the last flow was doing, it is over. Waiting for its socket
        // here is what lets this one bind the port it advertised last time,
        // rather than sliding down the ladder to one the authorize request was
        // never told about.
        await retireActive()
        for p in ports {
            guard let candidate = try? LoopbackCallback(
                port: p, successText: successText, expectedState: expectedState
            ) else { continue }
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
        var params: [String: String] = [:]
        if let comps = URLComponents(string: "http://localhost" + target) {
            for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
        }
        // A listener from a finished flow may briefly still be bound, and the
        // kernel is free to hand it a connection. It answers as a stranger
        // rather than claiming a sign-in it cannot deliver to anyone. A
        // callback carrying the wrong state gets the identical treatment —
        // and, crucially, does not settle the flow: the guessed request is
        // refused and the listener keeps waiting for the real one.
        let stateMatches = expectedState == nil || params["state"] == expectedState
        let isCallback = target.hasPrefix("/callback") && isCurrent && stateMatches

        let body = isCallback
            ? "<!doctype html><meta charset=utf-8><title>Done</title><body style=\"font:15px -apple-system,sans-serif;display:grid;place-items:center;height:100vh;margin:0\">\(successText)</body>"
            : "<!doctype html><meta charset=utf-8><title>Not found</title><body>Not found.</body>"
        let status = isCallback ? "200 OK" : "404 Not Found"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"

        conn.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { conn.cancel(); return }
            self.queue.async { self.forget(conn) }
        })

        guard isCallback, !settled else { return }
        settled = true
        resultCont?.resume(returning: params)
        resultCont = nil
    }
}

extension OAuth {
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
        let result = try await signInIdentified(persistRefreshToken: persistRefreshToken)
        return (result.email ?? "Claude account", result.refreshToken)
    }

    /// The same sign-in, reporting who it actually signed in as: the email and
    /// the Anthropic account UUID, each nil when neither the token response nor
    /// the profile said. Promotion needs both to be sure the person signed into
    /// the account they meant to, rather than trusting a placeholder.
    static func signInIdentified(
        persistRefreshToken: ((String) throws -> Void)? = nil
    ) async throws -> (email: String?, refreshToken: String, accountId: String?) {
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
        var email = bundle.email?.isEmpty == false ? bundle.email : nil
        var accountId = AccountIdentity.normalize(bundle.accountId)
        if email == nil || accountId == nil,
           let profile = try? await fetchProfile(accessToken: bundle.accessToken) {
            if email == nil, let found = profile.email, !found.isEmpty { email = found }
            if accountId == nil { accountId = AccountIdentity.normalize(profile.accountId) }
        }
        return (email, refresh, accountId)
    }

}
