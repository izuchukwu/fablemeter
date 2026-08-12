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

    /// Showing real numbers that are no longer being refreshed.
    var isStale: Bool { error != nil && snapshot != nil }
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
                isUnreachable: state?.error != nil
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
        if retry[account.id]?.isBlocked(at: now) == true { return false }
        guard let maxAge = reason.maxAge else { return true }
        guard let last = lastAttempt[account.id] else { return true }
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
            schedule.recordSuccess()
            lastUpdated = Date()
        case .failure(let message, let kind, let retryAfter):
            // The last good numbers stay exactly where they are; only the
            // verdict changes and the track goes hollow.
            state.error = message
            schedule.recordFailure(kind, retryAfter: retryAfter)
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

    private enum FetchOutcome {
        case success(UsageSnapshot)
        case failure(message: String, kind: Backoff.Failure, retryAfter: Date?)
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
        } catch let error as UsageError {
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
        } catch let error as OAuthError {
            return .failure(
                message: error.errorDescription ?? "sign-in failed",
                kind: .transient, retryAfter: nil
            )
        } catch {
            return .failure(
                message: error.localizedDescription, kind: .transient, retryAfter: nil
            )
        }
    }

    // MARK: Accounts

    func addAccount() {
        guard canAddAccount else { return }
        isSigningIn = true
        signInError = nil
        Task {
            do {
                let (email, refreshToken) = try await OAuth.signIn()
                var updated = accounts.filter { $0.email.caseInsensitiveCompare(email) != .orderedSame }
                updated.append(Account(email: email, refreshToken: refreshToken))
                accounts = updated
                Store.save(updated)
                isSigningIn = false
                await refresh(reason: .manual)
            } catch {
                signInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        Store.save(accounts)
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
        if !isDemo { Store.save(accounts) }
    }

    func setLabel(_ raw: String, for account: Account) {
        guard let normalized = Account.normalizeLabel(raw),
              let idx = accounts.firstIndex(where: { $0.id == account.id }),
              accounts[idx].label != normalized else { return }
        accounts[idx].label = normalized
        if !isDemo { Store.save(accounts) }
    }

    func setNickname(_ raw: String, for account: Account) {
        let normalized = Account.normalizeNickname(raw) ?? Account.localPart(of: account.email)
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }),
              accounts[idx].nickname != normalized else { return }
        accounts[idx].nickname = normalized
        if !isDemo { Store.save(accounts) }
    }

    // MARK: Demo

    /// `--demo`: three in-memory accounts covering every state worth looking at
    /// without signing in — blocked (dimmed letter, empty painted gauge), rate
    /// limited but still showing its last known reading (hollow gauge), and
    /// plain healthy monochrome. Plus a 100% row and a Fable bucket the API
    /// never reported, which is the `0%` + `—` case.
    private static func demoData() -> (accounts: [Account], states: [UUID: AccountState]) {
        let specs: [(
            label: String, nickname: String, email: String,
            five: Double, weekly: Double, fable: Double?, error: String?
        )] = [
            ("P", "Personal", "izu@personal.com", 100, 5, nil, nil),
            ("W", "Work", "izu@work.example", 78, 20, 40, "rate limited"),
            ("T", "Team", "izu@team.example", 15, 5, 10, nil)
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
            states[account.id] = AccountState(snapshot: snap, error: spec.error)
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
