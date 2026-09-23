import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security)
import Security
#endif

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
        #if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, count, &buf) != errSecSuccess {
            for i in 0..<count { buf[i] = UInt8.random(in: 0...255) }
        }
        #else
        // No Security framework off Apple platforms. `SystemRandomNumberGenerator`
        // is the platform CSPRNG there (getrandom on Linux), so this is not a
        // weaker fallback, it is the primary source.
        var rng = SystemRandomNumberGenerator()
        for i in 0..<count { buf[i] = UInt8.random(in: 0...255, using: &rng) }
        #endif
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


    static func exchange(code: String, verifier: String, redirectURI: String, state: String) async throws -> TokenBundle {
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

        let (data, response) = try await HTTP.data(for: req)
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
        let (data, _) = try await HTTP.data(for: req)
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
