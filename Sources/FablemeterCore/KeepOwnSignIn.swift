import Foundation

/// Before a promotion asks for a fresh sign-in, test the sign-in this machine
/// already holds.
///
/// A follower keeps every account and its refresh token; it only stops polling.
/// Those tokens are this machine's own lineage: nothing in Fablemeter ever
/// copies a token between machines, and this check reads only this machine's
/// own store. So when a machine is promoted back, an account whose own token
/// still refreshes AND still belongs to the row it sits in has nothing to gain
/// from a new sign-in.
///
/// Tested, never assumed: the token is spent for real (a forced refresh through
/// the vault, under its per-account refresh lock, rotation persisted before
/// anything else), and the identity the refresh reports is judged by the same
/// `SignInCheck` verdict a fresh sign-in gets. Anything short of a proven
/// match — rejected, unreachable, unidentified, another account — asks for a
/// sign-in, exactly as before.
enum KeepOwnSignIn {
    enum Probe: Equatable {
        /// The stored token refreshed. Who it says it is, as far as it says.
        case refreshed(accountId: String?, email: String?)
        /// Anthropic refused the stored token (expired, revoked, invalid_grant).
        case rejected
        /// The check could not be completed (network, busy lock, server error).
        case unreachable
    }

    enum Reason: Equatable {
        case rejected, wrongAccount, unidentified, unreachable

        var text: String {
            switch self {
            case .rejected: return "stored sign-in expired"
            case .wrongAccount: return "stored sign-in is another account"
            case .unidentified: return "could not confirm which account it is"
            case .unreachable: return "could not check the stored sign-in"
            }
        }
    }

    enum Decision: Equatable {
        case keep
        case signIn(Reason)
    }

    typealias Profile = @Sendable (_ accessToken: String) async throws -> (email: String?, accountId: String?)?
    typealias Remember = @Sendable (_ row: UUID, _ accountId: String?) -> Void

    /// Pure: what to do with an account given what testing its token showed.
    /// Only `.match` keeps. `.establish` (a row that never learned who it is)
    /// asks for a sign-in, because there is nothing to confirm the token against.
    static func decide(row: SignInCheck.Row, rows: [SignInCheck.Row], probe: Probe) -> Decision {
        switch probe {
        case .rejected: return .signIn(.rejected)
        case .unreachable: return .signIn(.unreachable)
        case .refreshed(let accountId, let email):
            switch SignInCheck.verdict(target: row, accountId: accountId, email: email, rows: rows) {
            case .match: return .keep
            case .belongsTo, .mismatch: return .signIn(.wrongAccount)
            case .establish, .unidentified: return .signIn(.unidentified)
            }
        }
    }

    /// Spend the stored token once, for real, and report what came back. The
    /// vault takes the account's refresh lock and persists the rotation itself,
    /// so this follows exactly the rules every ordinary refresh follows.
    static func probe(_ account: Account, vault: TokenVault, profile: Profile = { try await OAuth.fetchProfile(accessToken: $0) }) async -> Probe {
        // A rejection remembered from earlier is not a test: clear it and ask.
        await vault.forget(account.id)
        let access: String
        do {
            access = try await vault.accessToken(for: account, force: true)
        } catch let error as OAuthError where error.isCredentialRejected {
            return .rejected
        } catch {
            return .unreachable
        }
        var accountId: String? = nil
        var email: String? = nil
        if let identity = await vault.identity(of: account.id) {
            accountId = identity.accountId
            email = SignInCheck.isRealEmail(identity.email) ? identity.email : nil
        }
        if accountId == nil, let fetched = try? await profile(access) {
            accountId = fetched.accountId
            if email == nil, SignInCheck.isRealEmail(fetched.email) { email = fetched.email }
        }
        return .refreshed(accountId: accountId, email: email)
    }

    /// Probe, then decide. On a kept row that never stored its Anthropic
    /// account id, the id the refresh reported is remembered (it was just
    /// confirmed against the row's real address).
    static func check(
        _ account: Account,
        rows: [SignInCheck.Row],
        vault: TokenVault,
        profile: Profile = { try await OAuth.fetchProfile(accessToken: $0) },
        remember: Remember = { AccountIdentity.remember($0, accountId: $1) }
    ) async -> Decision {
        let row = rows.first(where: { $0.id == account.id })
            ?? SignInCheck.Row(id: account.id, accountId: nil, email: account.email)
        let result = await probe(account, vault: vault, profile: profile)
        let decision = decide(row: row, rows: rows, probe: result)
        if decision == .keep, row.accountId == nil, case .refreshed(let id?, _) = result {
            remember(account.id, id)
        }
        return decision
    }

    /// "✓ Iconic: kept this Mac's sign-in"
    static func keptText(nickname: String, machine: String) -> String {
        "✓ \(nickname): kept \(machine)'s sign-in"
    }

    /// "Checking Iconic (1 of 3)…"
    static func checkingText(nickname: String, index: Int, count: Int) -> String {
        "Checking \(nickname) (\(index) of \(count))…"
    }
}

extension CoreChecks {
    // MARK: Promote keeps a machine's own working sign-in

    static func keepOwnSignIn(_ check: Check) {
        let iconicId = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
        let personalId = "5b2d6c1e-9f1a-4c3b-8e7d-2a1b3c4d5e6f"
        let iconic = Account(email: "izu@iconic.test", nickname: "Iconic", label: "I", refreshToken: "own-token")
        let personal = Account(email: "izu@personal.test", nickname: "Personal", label: "P", refreshToken: "p-token")
        let rows = [
            SignInCheck.Row(id: iconic.id, accountId: iconicId, email: iconic.email),
            SignInCheck.Row(id: personal.id, accountId: personalId, email: personal.email),
        ]
        struct Stub: Error {}

        /// Runs the real probe + decision against a vault whose refresher is
        /// scripted, so the token path is the production one end to end.
        func run(_ refresher: @escaping TokenVault.Refresher, rows: [SignInCheck.Row] = rows,
                 profile: @escaping KeepOwnSignIn.Profile = { _ in nil }) -> (KeepOwnSignIn.Decision, [String], [String]) {
            let spent = Locked<[String]>(initialState: [])
            let remembered = Locked<[String]>(initialState: [])
            let vault = TokenVault(
                refresher: { token in spent.withLock { $0.append(token) }; return try await refresher(token) },
                storedToken: { _ in "own-token" },
                persist: { _, _, _ in },
                lock: { _ in nil }
            )
            let done = DispatchSemaphore(value: 0)
            let out = Locked<KeepOwnSignIn.Decision?>(initialState: nil)
            Task.detached {
                let d = await KeepOwnSignIn.check(iconic, rows: rows, vault: vault, profile: profile,
                                                  remember: { _, id in remembered.withLock { $0.append(id ?? "nil") } })
                out.withLock { $0 = d }
                done.signal()
            }
            done.wait()
            return (out.withLock { $0 } ?? .signIn(.unreachable), spent.withLock { $0 }, remembered.withLock { $0 })
        }
        @Sendable func bundle(_ id: String?, _ email: String?) -> TokenBundle {
            TokenBundle(accessToken: "a", refreshToken: "rotated", expiresAt: Date().addingTimeInterval(3600), email: email, accountId: id)
        }

        let kept = run { _ in bundle(iconicId, "izu@iconic.test") }
        check("keep: this machine's own working token is kept, no sign-in",
              kept.0 == .keep, "\(kept.0)")
        check("keep: …and it was actually tested with the stored token, once",
              kept.1 == ["own-token"], "\(kept.1)")

        let expired = run { _ in throw OAuthError.tokenExchange(400, "{\"error\":\"invalid_grant\"}") }
        check("keep: a rejected token (invalid_grant) asks for a sign-in",
              expired.0 == .signIn(.rejected), "\(expired.0)")
        let revoked = run { _ in throw OAuthError.tokenExchange(401, "unauthorized") }
        check("keep: a revoked token (401) asks for a sign-in",
              revoked.0 == .signIn(.rejected), "\(revoked.0)")
        let offline = run { _ in throw URLError(.notConnectedToInternet) }
        check("keep: a check that could not complete asks for a sign-in, never keeps",
              offline.0 == .signIn(.unreachable), "\(offline.0)")
        let busy = run { _ in throw OAuthError.refreshBusy }
        check("keep: a busy refresh lock asks for a sign-in, never keeps",
              busy.0 == .signIn(.unreachable), "\(busy.0)")

        let wrong = run { _ in bundle(personalId, "izu@personal.test") }
        check("keep: a token that is another row's account asks for a sign-in",
              wrong.0 == .signIn(.wrongAccount), "\(wrong.0)")
        let stranger = run { _ in bundle("11111111-2222-4333-8444-555555555555", "who@else.test") }
        check("keep: a token that is an account no row holds asks for a sign-in",
              stranger.0 == .signIn(.wrongAccount), "\(stranger.0)")
        let silent = run { _ in bundle(nil, nil) }
        check("keep: a token that says nothing about who it is asks for a sign-in",
              silent.0 == .signIn(.unidentified), "\(silent.0)")

        let viaProfile = run({ _ in bundle(nil, nil) }, profile: { _ in ("izu@iconic.test", iconicId) })
        check("keep: identity missing from the refresh is read from the profile",
              viaProfile.0 == .keep, "\(viaProfile.0)")
        let profileWrong = run({ _ in bundle(nil, nil) }, profile: { _ in ("izu@personal.test", personalId) })
        check("keep: …and a profile naming another account asks for a sign-in",
              profileWrong.0 == .signIn(.wrongAccount), "\(profileWrong.0)")

        let noIdRows = [SignInCheck.Row(id: iconic.id, accountId: nil, email: iconic.email), rows[1]]
        let learned = run({ _ in bundle(iconicId, "izu@iconic.test") }, rows: noIdRows)
        check("keep: a row matched by address learns its account id",
              learned.0 == .keep && learned.2 == [iconicId], "\(learned)")
        let blankRows = [SignInCheck.Row(id: iconic.id, accountId: nil, email: SignInCheck.placeholderEmail), rows[1]]
        let blank = run({ _ in bundle(iconicId, "izu@iconic.test") }, rows: blankRows)
        check("keep: a row that never knew who it is cannot be confirmed, so it signs in",
              blank.0 == .signIn(.unidentified) && blank.2.isEmpty, "\(blank)")

        check("keep: the kept line reads short",
              KeepOwnSignIn.keptText(nickname: "Iconic", machine: "this Mac") == "✓ Iconic: kept this Mac's sign-in", "")
    }
}
