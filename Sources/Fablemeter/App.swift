import AppKit
import os
import ServiceManagement
import SwiftUI

/// The app's own log, one subsystem so `log show --predicate 'subsystem ==
/// "com.izu.fablemeter"'` returns this app's lines and nothing else.
///
/// Not `NSLog`: the unified log redacts a dynamic string argument as `<private>`
/// unless the call site says otherwise, so an `NSLog("%@", line)` writes a
/// perfectly formatted diagnostic that nobody can ever read back. `Logger` can
/// mark the interpolation public, and it does not parse the string as a format,
/// so a server-supplied bucket label cannot be read as one either.
enum Log {
    static let usage = Logger(subsystem: "com.izu.fablemeter", category: "usage")
    static let store = Logger(subsystem: "com.izu.fablemeter", category: "store")
    static let push = Logger(subsystem: "com.izu.fablemeter", category: "push")
}

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

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var states: [UUID: AccountState] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    /// True only while a refresh the *user* asked for is in flight. The footer's
    /// reload control spins on this and nothing else: a scheduled pass runs
    /// every five minutes behind the popover and must not make the footer twitch
    /// while it is open.
    @Published private(set) var isManualRefreshing = false
    @Published var isSigningIn = false
    @Published var signInError: String?
    /// True while the web-companion handoff is in flight, so the menu item
    /// cannot stack a second listener behind the first.
    @Published private(set) var isConnectingWeb = false
    /// Whether the gauge counts Fable in its minimum — see
    /// `UsageSnapshot.headroom(fableFirst:)`. On by default, and `object(forKey:)`
    /// rather than `bool(forKey:)` on purpose: an absent key means the default,
    /// and only a stored `false` means the user turned it off — the same
    /// missing-versus-reported distinction the readings themselves live by.
    @Published var isFableFirst: Bool = UserDefaults.standard
        .object(forKey: "fableFirst") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isFableFirst, forKey: "fableFirst") }
    }
    /// The warning toggles, same absent-key-means-default pattern as above.
    /// All default ON: this feature exists because a window went 0 to 100 in
    /// half an hour with nothing said.
    @Published var warnAt75: Bool = UserDefaults.standard
        .object(forKey: "warnAt75") as? Bool ?? true {
        didSet { UserDefaults.standard.set(warnAt75, forKey: "warnAt75") }
    }
    @Published var warnAt90: Bool = UserDefaults.standard
        .object(forKey: "warnAt90") as? Bool ?? true {
        didSet { UserDefaults.standard.set(warnAt90, forKey: "warnAt90") }
    }
    @Published var warnAt95: Bool = UserDefaults.standard
        .object(forKey: "warnAt95") as? Bool ?? true {
        didSet { UserDefaults.standard.set(warnAt95, forKey: "warnAt95") }
    }
    @Published var warnFastBurn: Bool = UserDefaults.standard
        .object(forKey: "warnFastBurn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(warnFastBurn, forKey: "warnFastBurn") }
    }

    private var warnSettings: WarnSettings {
        WarnSettings(at75: warnAt75, at90: warnAt90, at95: warnAt95, fastBurn: warnFastBurn)
    }

    let isDemo: Bool
    private let vault = TokenVault()
    /// Absent in demo mode, so fixture accounts can never reach the wire.
    private var pusher: Pusher?
    private let warner = Warner()
    private var pollTask: Task<Void, Never>?
    private var lastManualRefresh: Date = .distantPast
    /// When each account was last *asked* — success or failure. The ordinary
    /// schedule is measured from here.
    private var lastAttempt: [UUID: Date] = [:]
    /// Per-account backoff. The one gate no refresh reason may override.
    private var retry: [UUID: RetrySchedule] = [:]
    private var isPassRunning = false

    init(demo: Bool = false, demoCount: Int? = nil) {
        isDemo = demo
        if demo {
            let seeded = AppState.demoData(count: demoCount)
            accounts = seeded.accounts
            states = seeded.states
            lastUpdated = Date()
            return
        }
        accounts = Store.load()
        pusher = Pusher()
        // The loop wakes often but asks each account's own schedule whether it
        // is due, so waking is free — only a due account costs a request.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(reason: .scheduled)
                // Unconditional, and outside every branch above it: there is no
                // path through this loop that gets back to the top without
                // waiting.
                try? await Task.sleep(nanoseconds: PollPolicy.tickNanoseconds)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: .opportunistic) }
        }
    }

    var canAddAccount: Bool { !isDemo && !isSigningIn }

    /// What the status item draws, one cell per account. `headroom` is the last
    /// reading that arrived even when the newest attempt failed, so a 429 dims
    /// the gauge's track rather than emptying it.
    var barCells: [BarCell] {
        accounts.map { account in
            // Derived from the snapshot on every draw, so an account flips to
            // yellow the moment Fable hits 100% and back the moment its week
            // resets — no relaunch, and per account. The Fable-first toggle
            // repaints the same way: it is `@Published`, so flipping it redraws
            // every cell through the same factory the selftest exercises.
            BarCell.cell(
                character: account.character,
                state: states[account.id],
                fableFirst: isFableFirst
            )
        }
    }

    func state(for account: Account) -> AccountState? { states[account.id] }

    // MARK: Refreshing
    //
    // Two gates stand between a reason to refresh and an actual request:
    //
    //   backoff   — set only by a failure, and overridable by nothing. Manual
    //               refresh does not escape it; that is the whole point.
    //   staleness — how old the on-screen reading may be before this particular
    //               reason justifies spending a request (`RefreshReason.maxAge`).
    //
    // Everything that used to call `refreshAll()` now names its reason, so the
    // popover opening and the machine waking can no longer stack extra requests
    // on top of the poll loop.

    func refresh(reason: RefreshReason) async {
        guard !isDemo else { return }
        guard !accounts.isEmpty else {
            lastUpdated = Date()
            return
        }
        // One pass at a time: a pass sleeps between accounts, so overlapping
        // passes would reintroduce exactly the burst the stagger removes.
        guard !isPassRunning else { return }
        isPassRunning = true
        defer { isPassRunning = false }

        let now = Date()
        let due = accounts.filter { isDue($0, reason: reason, now: now) }
        guard !due.isEmpty else { return }

        isRefreshing = true
        defer { isRefreshing = false }
        for (index, account) in due.enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: UInt64(PollPolicy.stagger * 1_000_000_000))
            }
            // The account may have been signed out mid-pass.
            guard accounts.contains(where: { $0.id == account.id }) else { continue }
            await fetch(account)
        }
        // The pass is over and the state is whatever the gauge now shows —
        // successes, failures and staleness alike — so this is the one moment
        // the web companion hears about it. Fire and forget: nothing past this
        // line can touch the gauge, the schedule, or the screen.
        pusher?.push(accounts: accounts, states: states, fableFirst: isFableFirst)
    }

    private func isDue(_ account: Account, reason: RefreshReason, now: Date) -> Bool {
        Self.isDue(
            needsSignIn: states[account.id]?.needsSignIn == true,
            retry: retry[account.id],
            lastAttempt: lastAttempt[account.id],
            reason: reason,
            now: now
        )
    }

    /// Pure, so `--selftest` can prove the gates without a network or a clock.
    /// A dead credential is not a schedule problem: no reason, not even a manual
    /// refresh, may put it back on the wire, and the backoff ladder must not be
    /// left churning on something that will never succeed.
    nonisolated static func isDue(
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

    private func fetch(_ account: Account) async {
        lastAttempt[account.id] = Date()
        let outcome = await Self.load(account, vault: vault)
        guard accounts.contains(where: { $0.id == account.id }) else { return }

        // What the account now *is* — snapshot, verdict, sign-in — decided in
        // one pure place and applied whole. What follows only decides when to
        // ask again and what to write to the log; nothing below touches the
        // state, so no path can set an error and clear a reading as two
        // separate steps.
        let state = AccountState.applying(outcome, to: states[account.id])
        var schedule = retry[account.id] ?? RetrySchedule()
        switch outcome {
        case .success(let snapshot):
            schedule.recordSuccess()
            lastUpdated = Date()
            // The poll already happened, so the shape of what it decoded is
            // free to record — and it is the only way to tell a null percent
            // from a reported zero without spending another refresh token.
            // Explicitly public: the usage payload carries no credential, and a
            // line the log redacts is a line that never gets read.
            if !isDemo {
                let line = UsageLog.line(label: account.character, snapshot: snapshot)
                Log.usage.notice("\(line, privacy: .public)")
            }
        case .failure(let message, let kind, let retryAfter):
            schedule.recordFailure(kind, retryAfter: retryAfter)
            // The counterpart to the success line, and the reason this exists:
            // the log recorded every reading that arrived and nothing at all
            // about the ones that did not, so an app sitting on three stale
            // accounts left no trace of why. Diagnosing that meant reading a
            // screenshot and guessing which account a number belonged to.
            // `message` is the string `outcome(for:)` already vetted for the
            // screen, so no response body can reach here either.
            if !isDemo {
                let line = UsageLog.failureLine(
                    label: account.character, message: message,
                    kind: kind, attempt: schedule.failures
                )
                Log.usage.notice("\(line, privacy: .public)")
            }
        case .needsSignIn:
            // The ladder is wiped rather than climbed, so re-authenticating
            // starts from a clean schedule.
            schedule = RetrySchedule()
        }
        // Warnings are decided against the reading being replaced, which is
        // the last one that ever arrived (failures keep it), so this happens
        // before the state lands. Only a fresh reading can warn: a failure has
        // nothing new to compare and demo fixtures never notify.
        if case .success(let snapshot) = outcome, !isDemo {
            warner.deliver(WarnPolicy.assess(
                name: account.nickname,
                label: account.character,
                previous: states[account.id]?.snapshot,
                current: snapshot,
                now: Date(),
                settings: warnSettings,
                fired: warner.fired
            ))
        }
        states[account.id] = state
        retry[account.id] = schedule
    }

    func manualRefresh() {
        guard !isManualRefreshing else { return }
        guard Date().timeIntervalSince(lastManualRefresh) >= PollPolicy.manualDebounce else { return }
        lastManualRefresh = Date()
        isManualRefreshing = true
        Task {
            // Cleared on every path out, including a thrown-away pass that was
            // never due — the control must never be left spinning.
            defer { isManualRefreshing = false }
            let started = Date()
            await refresh(reason: .manual)
            // A cached or instantly-failing pass returns in milliseconds; the
            // spinner still has to be seen to mean anything.
            let padding = PollPolicy.spinPadding(elapsed: Date().timeIntervalSince(started))
            if padding > 0 {
                try? await Task.sleep(nanoseconds: UInt64(padding * 1_000_000_000))
            }
        }
    }

    /// `--render-popover` only, and only in a demo build: the spinning reload
    /// control is a state worth eyeballing and a real refresh never lasts long
    /// enough to photograph. Refused outright anywhere else, so nothing in the
    /// shipping app can pin the control on.
    func beginDemoSpin() {
        guard isDemo else { return }
        isManualRefreshing = true
    }

    /// Popover open and wake from sleep: worth a request only if what is on
    /// screen has actually gone stale.
    func refreshIfStale() {
        guard !isDemo else { return }
        Task { await refresh(reason: .opportunistic) }
    }

    private static func load(_ account: Account, vault: TokenVault) async -> FetchOutcome {
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
    nonisolated static func signInMessage(for error: Error) -> String {
        if let error = error as? OAuthError { return error.displayText }
        if let error = error as? ConnectError { return error.displayText }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    nonisolated static func outcome(for error: Error) -> FetchOutcome {
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

    // MARK: Accounts
    //
    // Nothing here ever writes the in-memory array over the file. The array is
    // a view of the accounts; the file is the authority on their refresh
    // tokens, and a rotation that landed on disk a second ago must survive a
    // rename, a reorder or a sign-out carrying a stale copy of it.

    /// Applies a change to what is actually on disk. Never used for anything
    /// that carries a credential — those paths throw so the failure is visible.
    private func persistAccounts(_ body: @escaping (inout [Account]) -> Void) {
        guard !isDemo else { return }
        do {
            try Store.mutate(body)
        } catch {
            let reason = error.localizedDescription
            Log.store.error("failed to save accounts: \(reason, privacy: .public)")
        }
    }

    func addAccount() {
        guard canAddAccount else { return }
        isSigningIn = true
        signInError = nil
        Task {
            do {
                let (email, refreshToken) = try await OAuth.signIn()
                let account = Account(email: email, refreshToken: refreshToken)
                // Disk first: the token it carries exists nowhere else.
                try Store.mutate { stored in
                    stored.removeAll { $0.email.caseInsensitiveCompare(email) == .orderedSame }
                    stored.append(account)
                }
                accounts = accounts.filter {
                    $0.email.caseInsensitiveCompare(email) != .orderedSame
                } + [account]
                isSigningIn = false
                await refresh(reason: .manual)
            } catch {
                signInError = Self.signInMessage(for: error)
                isSigningIn = false
            }
        }
    }

    /// The web companion's localhost handoff, from the ⋯ menu. On success the
    /// key is in the Keychain and the pusher picks it up on the next pass —
    /// no relaunch, nothing else to do. Failures land in the same banner as
    /// sign-in failures, in the same vetted vocabulary.
    func connectWeb() {
        guard !isDemo, !isConnectingWeb else { return }
        isConnectingWeb = true
        signInError = nil
        Task {
            do {
                try await Connect.run()
                Log.push.notice("connect: key stored")
            } catch {
                signInError = Self.signInMessage(for: error)
            }
            isConnectingWeb = false
        }
    }

    /// Re-authenticate an account in place — offered on every account, not only
    /// one whose refresh token the server has already rejected. The account
    /// keeps its id, nickname, label and place in the order; only the
    /// credential underneath it is replaced.
    func signInAgain(_ account: Account) {
        guard !isDemo, !isSigningIn else { return }
        isSigningIn = true
        signInError = nil
        let id = account.id
        Task {
            do {
                // The new token goes to disk the instant it exists, under this
                // account's own id, before the profile lookup that follows.
                let (email, refreshToken) = try await OAuth.signIn(persistRefreshToken: { token in
                    try Store.updateRefreshToken(id: id, to: token)
                })
                guard let index = accounts.firstIndex(where: { $0.id == id }) else {
                    isSigningIn = false
                    return
                }
                let clash = accounts.contains {
                    $0.id != id && $0.email.caseInsensitiveCompare(email) == .orderedSame
                }
                guard !clash else {
                    signInError = "\(email) is already signed in."
                    isSigningIn = false
                    return
                }
                try Store.mutate { stored in
                    guard let idx = stored.firstIndex(where: { $0.id == id }) else { return }
                    stored[idx].email = email
                    stored[idx].refreshToken = refreshToken
                }
                accounts[index].email = email
                accounts[index].refreshToken = refreshToken
                states[id]?.needsSignIn = false
                states[id]?.error = nil
                retry[id] = nil
                lastAttempt[id] = nil
                await vault.reset(id)
                isSigningIn = false
                await refresh(reason: .manual)
            } catch {
                signInError = Self.signInMessage(for: error)
                isSigningIn = false
            }
        }
    }

    func remove(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        states[account.id] = nil
        lastAttempt[account.id] = nil
        retry[account.id] = nil
        guard !isDemo else { return }
        persistAccounts { $0.removeAll { $0.id == account.id } }
        Task { await vault.forget(account.id) }
    }

    // MARK: Order
    //
    // The menu bar draws `accounts` left to right, so reordering the array *is*
    // the feature. Every path writes through immediately: the status item
    // redraws off `objectWillChange`, so the cluster rearranges as the drag
    // crosses each row rather than on drop.

    func canMove(_ account: Account, by delta: Int) -> Bool {
        AccountOrder.shifted(accounts, id: account.id, by: delta) != nil
    }

    func move(_ account: Account, by delta: Int) {
        guard let reordered = AccountOrder.shifted(accounts, id: account.id, by: delta) else { return }
        applyOrder(reordered)
    }

    func move(_ account: Account, onto target: Account) {
        guard let reordered = AccountOrder.moved(accounts, id: account.id, onto: target.id) else { return }
        applyOrder(reordered)
    }

    private func applyOrder(_ reordered: [Account]) {
        accounts = reordered
        let order = reordered.map(\.id)
        persistAccounts { stored in
            stored = AccountOrder.sorted(stored, by: order)
        }
    }

    func setLabel(_ raw: String, for account: Account) {
        guard let normalized = Account.normalizeLabel(raw),
              let idx = accounts.firstIndex(where: { $0.id == account.id }),
              accounts[idx].label != normalized else { return }
        accounts[idx].label = normalized
        persistAccounts { stored in
            guard let i = stored.firstIndex(where: { $0.id == account.id }) else { return }
            stored[i].label = normalized
        }
    }

    func setNickname(_ raw: String, for account: Account) {
        let normalized = Account.normalizeNickname(raw) ?? Account.localPart(of: account.email)
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }),
              accounts[idx].nickname != normalized else { return }
        accounts[idx].nickname = normalized
        persistAccounts { stored in
            guard let i = stored.firstIndex(where: { $0.id == account.id }) else { return }
            stored[i].nickname = normalized
        }
    }

    // MARK: Demo

    /// `--demo`: eight in-memory accounts covering every state worth looking at
    /// without signing in — blocked (dimmed letter, empty painted gauge), rate
    /// limited but still showing its last known reading (hollow gauge), plain
    /// healthy monochrome, a dead credential waiting on a sign-in, Fable spent
    /// with room left everywhere else (yellow letter), and Fable spent on an
    /// account that is blocked anyway (dimmed yellow).
    ///
    /// The last two are the pair that used to be one state: an account the
    /// server reports as untouched (`0%` rows, a full gauge, `Available`) and an
    /// account the server reports nothing about at all (dashes, a hollow gauge,
    /// `No data`). Both used to read `Unknown` over three `0%` rows.
    nonisolated static func demoData(count: Int? = nil) -> (accounts: [Account], states: [UUID: AccountState]) {
        typealias Spec = (
            label: String, nickname: String, email: String,
            five: Double?, weekly: Double?, fable: Double?, error: String?, needsSignIn: Bool
        )
        // The showcase set, for a count: healthy, painted, and varied —
        // comfortable, mid, and tight-enough-to-tier — because a product shot
        // of the every-state set below reads as a wall of failures. Asking for
        // more than it holds gets all of it rather than sliding into the
        // failure states; the full set stays what a bare `--demo` means.
        let showcase: [Spec] = [
            ("P", "Personal", "izu@personal.example", 15, 10, 12, nil, false),
            ("W", "Work", "izu@work.example", 55, 40, 30, nil, false),
            ("T", "Team", "izu@team.example", 88, 60, 75, nil, false),
        ]
        let fullSpecs: [Spec] = [
            ("P", "Personal", "izu@personal.com", 100, 5, nil, nil, false),
            ("W", "Work", "izu@work.example", 78, 20, 40, "rate limited", false),
            ("T", "Team", "izu@team.example", 15, 5, 10, nil, false),
            ("I", "Iconic", "izu@iconic.example", 0, 0, nil, nil, true),
            ("F", "Fable spent", "izu@fable.example", 30, 20, 100, nil, false),
            ("B", "Fable spent, blocked", "izu@both.example", 100, 45, 100, nil, false),
            ("U", "Untouched", "izu@untouched.example", 0, 0, 0, nil, false),
            ("N", "Nothing reported", "izu@nothing.example", nil, nil, nil, nil, false),
            // The pair that reads as a bug and is not one. `U` above and this
            // account hold the same reading — a server-reported zero everywhere
            // — and the only difference is that this one's newest fetch failed.
            // Side by side they are the answer to "why did that account lose its
            // numbers": it did not. It is an idle account, and an idle account's
            // last known reading is three zeros. The hollow track and the
            // verdict are the whole of what the failure changed.
            ("Z", "Idle, then timed out", "izu@idle.example", 0, 0, 0, "Timed out", false)
        ]
        let specs = count.map { Array(showcase.prefix(max(1, $0))) } ?? fullSpecs
        var accounts: [Account] = []
        var states: [UUID: AccountState] = [:]
        for spec in specs {
            let account = Account(
                email: spec.email, nickname: spec.nickname, label: spec.label,
                refreshToken: "demo"
            )
            // A null percent is a bucket the server sent with no reading in it,
            // which is not the same thing as a reported zero and no longer draws
            // like one: null dashes both columns, zero prints `0%` and dashes
            // only the reset — an untouched window has not started, so there is
            // nothing for it to reset to.
            func bucket(
                _ id: String, _ label: String, _ percent: Double?, in window: TimeInterval
            ) -> UsageBucket {
                UsageBucket(
                    id: id, label: label, percent: percent,
                    resetsAt: (percent ?? 0) > 0 ? Date().addingTimeInterval(window) : nil
                )
            }
            var snap = UsageSnapshot()
            snap.fiveHour = bucket("session", "5-hour", spec.five, in: 4080)
            snap.weekly = bucket("weekly", "Weekly", spec.weekly, in: 273_600)
            snap.scoped = [bucket("scoped:Fable", "Fable", spec.fable, in: 273_600)]
            accounts.append(account)
            states[account.id] = AccountState(
                // A rejected credential has nothing live behind it.
                snapshot: spec.needsSignIn ? nil : snap,
                error: spec.error,
                needsSignIn: spec.needsSignIn
            )
        }
        return (accounts, states)
    }
}

/// Start on login, wrapped around `SMAppService.mainApp`. The service's own
/// status is the checkbox's source of truth; UserDefaults records only that
/// enrollment already happened once, so a choice made here or in System
/// Settings is never overridden on a later launch.
enum LoginItem {
    private static let attemptedKey = "loginItemEnrollmentAttempted"

    /// `swift run` has no bundle, and registering a bare debug binary as a
    /// login item would enshrine a build path in System Settings. Only a real
    /// .app may enroll, or show the checkbox at all.
    static var isAvailable: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.store.error("login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// On by default, exactly once: the first launch of the installed app
    /// enrolls itself, and every later launch defers to whatever the checkbox
    /// or System Settings says now.
    static func enrollOnFirstLaunch(demo: Bool) {
        let defaults = UserDefaults.standard
        guard shouldAutoEnroll(attempted: defaults.bool(forKey: attemptedKey),
                               demo: demo,
                               bundled: isAvailable) else { return }
        defaults.set(true, forKey: attemptedKey)
        set(true)
    }

    /// Kept pure so the selftest can pin the policy without touching the
    /// real service.
    static func shouldAutoEnroll(attempted: Bool, demo: Bool, bundled: Bool) -> Bool {
        !attempted && !demo && bundled
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let demo: Bool
    private let demoCount: Int?
    private var state: AppState?
    private var statusBar: StatusBarController?

    init(demo: Bool, demoCount: Int? = nil) {
        self.demo = demo
        self.demoCount = demoCount
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LoginItem.enrollOnFirstLaunch(demo: demo)
        let state = AppState(demo: demo, demoCount: demoCount)
        self.state = state
        self.statusBar = StatusBarController(state: state)
    }
}
