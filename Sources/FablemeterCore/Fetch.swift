import Foundation

struct AccountState {
    /// The last reading that actually arrived. Deliberately kept across
    /// failures: a transient 429 must never wipe the numbers off the screen,
    /// so this only ever goes back to `nil` if nothing has *ever* loaded.
    var snapshot: UsageSnapshot?
    /// Set while the newest attempt is failing. Alongside a non-nil `snapshot`
    /// it means what is on screen is real but no longer live.
    var error: String?
    /// Terminal: the refresh token is dead server-side and only an interactive
    /// sign-in brings the account back. Mutually exclusive with `error` — this
    /// is not something to retry, so it is not phrased as a failure message, and
    /// no response body is kept anywhere near it.
    var needsSignIn = false

    /// Showing real numbers that are no longer being refreshed.
    var isStale: Bool { error != nil && snapshot != nil }

    /// Nothing live is arriving, whatever the reason — the gauge goes hollow.
    var isUnreachable: Bool { error != nil || needsSignIn }

    /// The entire state transition, in one pure place so `--selftest` can drive
    /// every outcome against every prior state without a network or a clock.
    /// `fetch` calls this and does nothing else to the state, so what the tests
    /// prove is what the app does — not a second copy of it that can drift.
    ///
    /// The invariant it exists to hold: **`snapshot` is written by exactly one
    /// case**, and that case is `.success`. Both halves of that matter, and the
    /// second only became sharp when `percent` went optional:
    ///
    ///   - A failure must not *clear* the snapshot. Blanking the numbers is the
    ///     thing this app must never do to a transient error — settled for 429s
    ///     and identical for every other kind.
    ///   - A failure must not *synthesise* one either. An empty `UsageSnapshot`
    ///     is no longer a neutral placeholder: `0%` now means the server
    ///     reported zero. A failure path that manufactured one would not be
    ///     blanking the UI, it would be asserting a measurement nobody took —
    ///     which is worse, because it looks like data.
    ///
    /// So all three accounts behave identically under an identical failure: each
    /// keeps whatever it last had, and the only thing that changes is the
    /// verdict word and the hollow track behind it.
    static func applying(_ outcome: FetchOutcome, to previous: AccountState?) -> AccountState {
        var state = previous ?? AccountState()
        switch outcome {
        case .success(let snapshot):
            state.snapshot = snapshot
            state.error = nil
            state.needsSignIn = false
        case .failure(let message, _, _):
            // The last good numbers stay exactly where they are — untouched,
            // not re-derived. Only the verdict changes and the track goes
            // hollow.
            state.error = message
            state.needsSignIn = false
        case .needsSignIn:
            // Terminal. No message, because there is nothing to wait out. The
            // snapshot is left alone here too: a dead credential does not make
            // the last reading untrue, and the row hides the metrics on its own
            // when there was never anything behind them.
            state.error = nil
            state.needsSignIn = true
        }
        return state
    }
}

/// What one attempt at an account came back with.
enum FetchOutcome {
    case success(UsageSnapshot)
    case failure(message: String, kind: Backoff.Failure, retryAfter: Date?)
    /// The refresh token is dead. Not a failure to retry — a state to fix.
    case needsSignIn
}
/// The per-account fetch policy, shared by the menu bar app and the headless
/// server so both decide *when to ask* and *what a failure means* in exactly
/// one place. `AppState` forwards to these; the selftest drives them.
enum Fetch {
    /// Pure, so `--selftest` can prove the gates without a network or a clock.
    /// A dead credential is not a schedule problem: no reason, not even a manual
    /// refresh, may put it back on the wire, and the backoff ladder must not be
    /// left churning on something that will never succeed.
    static func isDue(
        needsSignIn: Bool,
        retry: RetrySchedule?,
        lastAttempt: Date?,
        reason: RefreshReason,
        now: Date
    ) -> Bool {
        if needsSignIn { return false }
        if retry?.isBlocked(at: now) == true { return false }
        // An account that is failing offline has already had its next attempt
        // chosen for it, on a ladder that caps at a minute. The staleness gate
        // exists to stop the app spending requests on numbers that are still
        // fresh; these numbers are not being refreshed at all, and the attempt
        // costs the API nothing, so the ladder is the only gate it needs. Every
        // other failure — the 429 ladder above all — still waits for both.
        if retry?.isOffline == true { return true }
        guard let maxAge = reason.maxAge else { return true }
        guard let last = lastAttempt else { return true }
        return now.timeIntervalSince(last) >= maxAge
    }

    static func load(_ account: Account, vault: TokenVault) async -> FetchOutcome {
        do {
            let token = try await vault.accessToken(for: account)
            do {
                return .success(try await UsageClient.fetch(accessToken: token))
            } catch UsageError.unauthorized {
                let fresh = try await vault.accessToken(for: account, force: true)
                return .success(try await UsageClient.fetch(accessToken: fresh))
            }
        } catch {
            return outcome(for: error)
        }
    }

    /// Pure classification, so `--selftest` can assert that a 400 lands on the
    /// terminal state and that no response body survives the trip.
    /// The sign-in banner is still UI, so it gets the same treatment: a status
    /// code, never a body.
    static func outcome(for error: Error) -> FetchOutcome {
        // First, and once: every transport failure is answered here, in this
        // app's own words, whether it died on the token refresh or on the usage
        // call. `NetworkFailure.text(for:)` is total over `URLError`, so this
        // branch is the reason no Foundation sentence can reach the verdict
        // column — not a list of the ones anybody thought to name.
        if let text = NetworkFailure.text(for: error) {
            // Offline is the only kind that earns the tight ladder, and the
            // reason is narrow: the request failed locally in milliseconds
            // without ever reaching Anthropic, so retrying costs the API
            // literally nothing. A timeout cannot make that claim — the request
            // left, and the server may well have received it and be working on
            // it — so it stays on the transient ladder with the 5xx it most
            // resembles. Putting timeouts on the offline ladder would have this
            // app retry every 15 seconds against a server already too slow to
            // answer in ten, which is the one behaviour a passive observer must
            // never have.
            return .failure(
                message: text,
                kind: NetworkFailure.isOffline(error) ? .offline : .transient,
                retryAfter: nil
            )
        }
        if let error = error as? OAuthError {
            guard !error.isCredentialRejected else { return .needsSignIn }
            return .failure(message: error.displayText, kind: .transient, retryAfter: nil)
        }
        if let error = error as? UsageError {
            // Only a 429 is a real rate limit; everything else backs off on the
            // gentler transient schedule, but everything backs off, so no
            // failure mode can spin the loop.
            if case .rateLimited(let retryAfter) = error {
                return .failure(
                    message: error.errorDescription ?? "rate limited",
                    kind: .rateLimited, retryAfter: retryAfter
                )
            }
            return .failure(
                message: error.errorDescription ?? "failed", kind: .transient, retryAfter: nil
            )
        }
        // Nothing recognised. Still not `error.localizedDescription`: that was
        // the last door a raw NSError could walk through onto the screen, and an
        // error this app has no name for is precisely the one whose Foundation
        // sentence will be longest and least actionable. The raw text is not
        // lost — `fetch` logs the failure — it just does not go in the verdict.
        return .failure(
            message: NetworkFailure.genericText, kind: .transient, retryAfter: nil
        )
    }
}
