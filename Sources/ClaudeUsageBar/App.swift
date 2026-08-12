import AppKit
import SwiftUI

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
    @Published var isSigningIn = false
    @Published var signInError: String?

    let isDemo: Bool
    private let vault = TokenVault()
    private var pollTask: Task<Void, Never>?
    private var lastManualRefresh: Date = .distantPast
    /// When each account was last *asked* — success or failure. The ordinary
    /// schedule is measured from here.
    private var lastAttempt: [UUID: Date] = [:]
    /// Per-account backoff. The one gate no refresh reason may override.
    private var retry: [UUID: RetrySchedule] = [:]
    private var isPassRunning = false

    init(demo: Bool = false) {
        isDemo = demo
        if demo {
            let seeded = AppState.demoData()
            accounts = seeded.accounts
            states = seeded.states
            lastUpdated = Date()
            return
        }
        accounts = Store.load()
        // The loop wakes often but asks each account's own schedule whether it
        // is due, so waking is free — only a due account costs a request.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(reason: .scheduled)
                try? await Task.sleep(nanoseconds: UInt64(PollPolicy.tick * 1_000_000_000))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: .opportunistic) }
        }
    }

    var canAddAccount: Bool { !isDemo && accounts.count < Store.maxAccounts && !isSigningIn }

    /// What the status item draws, one cell per account. `headroom` is the last
    /// reading that arrived even when the newest attempt failed, so a 429 dims
    /// the gauge's track rather than emptying it.
    var barCells: [BarCell] {
        accounts.map { account in
            let state = states[account.id]
            return BarCell(
                character: account.character,
                headroom: state?.snapshot?.headroom,
                isUnreachable: state?.isUnreachable == true
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
        guard let maxAge = reason.maxAge else { return true }
        guard let last = lastAttempt else { return true }
        return now.timeIntervalSince(last) >= maxAge
    }

    private func fetch(_ account: Account) async {
        lastAttempt[account.id] = Date()
        let outcome = await Self.load(account, vault: vault)
        guard accounts.contains(where: { $0.id == account.id }) else { return }

        var state = states[account.id] ?? AccountState()
        var schedule = retry[account.id] ?? RetrySchedule()
        switch outcome {
        case .success(let snapshot):
            state.snapshot = snapshot
            state.error = nil
            state.needsSignIn = false
            schedule.recordSuccess()
            lastUpdated = Date()
        case .failure(let message, let kind, let retryAfter):
            // The last good numbers stay exactly where they are; only the
            // verdict changes and the track goes hollow.
            state.error = message
            state.needsSignIn = false
            schedule.recordFailure(kind, retryAfter: retryAfter)
        case .needsSignIn:
            // Terminal. No message, because there is nothing to wait out — and
            // the ladder is wiped rather than climbed, so re-authenticating
            // starts from a clean schedule.
            state.error = nil
            state.needsSignIn = true
            schedule = RetrySchedule()
        }
        states[account.id] = state
        retry[account.id] = schedule
    }

    func manualRefresh() {
        guard Date().timeIntervalSince(lastManualRefresh) >= PollPolicy.manualDebounce else { return }
        lastManualRefresh = Date()
        Task { await refresh(reason: .manual) }
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
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    nonisolated static func outcome(for error: Error) -> FetchOutcome {
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
        return .failure(
            message: error.localizedDescription, kind: .transient, retryAfter: nil
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
            NSLog("ClaudeUsageBar: failed to save accounts: \(error.localizedDescription)")
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

    /// `--demo`: four in-memory accounts covering every state worth looking at
    /// without signing in — blocked (dimmed letter, empty painted gauge), rate
    /// limited but still showing its last known reading (hollow gauge), plain
    /// healthy monochrome, and a dead credential waiting on a sign-in. Plus a
    /// 100% row and a Fable bucket the API never reported, which is the `0%` +
    /// `—` case.
    private static func demoData() -> (accounts: [Account], states: [UUID: AccountState]) {
        let specs: [(
            label: String, nickname: String, email: String,
            five: Double, weekly: Double, fable: Double?, error: String?, needsSignIn: Bool
        )] = [
            ("P", "Personal", "izu@personal.com", 100, 5, nil, nil, false),
            ("W", "Work", "izu@work.example", 78, 20, 40, "rate limited", false),
            ("T", "Team", "izu@team.example", 15, 5, 10, nil, false),
            ("I", "Iconic", "izu@iconic.example", 0, 0, nil, nil, true)
        ]
        var accounts: [Account] = []
        var states: [UUID: AccountState] = [:]
        for spec in specs {
            let account = Account(
                email: spec.email, nickname: spec.nickname, label: spec.label,
                refreshToken: "demo"
            )
            var snap = UsageSnapshot()
            snap.fiveHour = UsageBucket(
                id: "session", label: "5-hour", percent: spec.five,
                resetsAt: Date().addingTimeInterval(4080)
            )
            snap.weekly = UsageBucket(
                id: "weekly", label: "Weekly", percent: spec.weekly,
                resetsAt: Date().addingTimeInterval(273_600)
            )
            // A nil Fable is the API's "no data" sentinel: 0% with no reset.
            snap.scoped = [UsageBucket(
                id: "scoped:Fable", label: "Fable", percent: spec.fable ?? 0,
                resetsAt: spec.fable == nil ? nil : Date().addingTimeInterval(273_600)
            )]
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let demo: Bool
    private var state: AppState?
    private var statusBar: StatusBarController?

    init(demo: Bool) {
        self.demo = demo
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let state = AppState(demo: demo)
        self.state = state
        self.statusBar = StatusBarController(state: state)
    }
}
