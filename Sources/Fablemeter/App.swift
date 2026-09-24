import AppKit
@testable import FablemeterCore
import ServiceManagement
import SwiftUI

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
    /// Another machine is the owner's server. From then on this Mac never
    /// polls Anthropic and never refreshes a token: it is a follower. Learned
    /// from the web before the first poll of every launch, from a 409 on push,
    /// and — when the web cannot be reached — from `role.json`, so a follower
    /// that restarts stays one. Showing the server's numbers in the gauge is
    /// the follower UI, a separate step; until then the gauge says so honestly,
    /// and `state.json` keeps carrying the server's numbers for the fleet.
    ///
    /// A Mac with NO web key cannot ask the web anything and is never answered
    /// with a 409, so it cannot learn it was demoted. It keeps polling on its
    /// own sign-ins exactly as before roles existed: a separate token lineage,
    /// which bricks nothing, and it cannot push anyway. Connect it (⋯ menu) to
    /// make it a proper follower.
    @Published private(set) var isFollowingServer = false
    /// The last answer from `/api/state`: who the server is and which machines
    /// have checked in. The Server submenu is drawn from this and nothing else,
    /// so opening the menu never waits on the network.
    @Published private(set) var remote: RemoteState?
    /// The server's snapshot, rebuilt for drawing while this Mac follows.
    @Published private(set) var followed: FollowedSnapshot?
    @Published private(set) var hasWebKey = false
    @Published private(set) var isPromoting = false
    /// "Signing into Personal (1 of 3)…" while a promotion runs.
    @Published private(set) var promotionStep: String?
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
    /// Absent in demo mode for the same reason: the fleet reads this file to
    /// decide whether to start real work, and fixture numbers must never be
    /// what it reads.
    private var localState: LocalStateWriter?
    private let warner = Warner()
    private var pollTask: Task<Void, Never>?
    private var lastManualRefresh: Date = .distantPast
    /// When each account was last *asked* — success or failure. The ordinary
    /// schedule is measured from here.
    private var lastAttempt: [UUID: Date] = [:]
    /// Per-account backoff. The one gate no refresh reason may override.
    private var retry: [UUID: RetrySchedule] = [:]
    private var isPassRunning = false
    private var roleMemory: RoleMemory?
    private var lastFollowCheck: Date = .distantPast
    private var remoteFetchedAt: Date = .distantPast
    private var lastBackgroundCheck: Date = .distantPast
    private var promoteTask: Task<Void, Never>?
    private var loggedNoKey = false
    private let identity = IdentityResolver()

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
        hasWebKey = PushKeyStore.standard.currentKey() != nil
        pusher = Pusher()
        localState = LocalStateWriter()
        // A follower that restarts stays a follower, before anything else can
        // run: no pass may start until the role is settled.
        roleMemory = RoleMemory.load()
        if roleMemory?.stance == .follower { enterFollowerMode(persist: false) }
        // The loop wakes often but asks each account's own schedule whether it
        // is due, so waking is free — only a due account costs a request.
        pollTask = Task { [weak self] in
            // Ask the web who the server is BEFORE the first pass, so an
            // upgraded Mac never spends a poll pass (and a token rotation)
            // finding out by 409 that it should not have.
            await self?.settleRoleAtLaunch()
            while !Task.isCancelled {
                await self?.followIfFollowing()
                await self?.refreshRemoteIfDue()
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

    /// A promotion owns the sign-in while it runs: a second browser flow would
    /// race it for the loopback listener and the person's attention.
    var canAddAccount: Bool { !isDemo && !isSigningIn && !isPromoting }

    /// What the status item draws, one cell per account. `headroom` is the last
    /// reading that arrived even when the newest attempt failed, so a 429 dims
    /// the gauge's track rather than emptying it.
    var barCells: [BarCell] {
        if isFollowingServer, let followed, !followed.accounts.isEmpty {
            let now = Date()
            return followed.accounts.map {
                BarCell.cell(character: $0.character, state: followed.state(for: $0, now: now), fableFirst: isFableFirst)
            }
        }
        return accounts.map { account in
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
        guard !isFollowingServer else { return }
        // A promotion is re-signing accounts; nothing may refresh underneath it.
        guard !isPromoting else { return }
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

        // Still the server? Asked once per pass, before anything reaches
        // Anthropic — see `PrePass` for why per pass and not per account. A
        // pass happens at most every few minutes (plus a debounced manual
        // one), so this adds ~12 reads/hr, far under the web's 600/hr cap.
        guard await stillMayPoll() else { return }

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
        pusher?.push(
            accounts: accounts, states: states, fableFirst: isFableFirst,
            warnings: warner.ledger.recent(),
            onNotServer: { Task { @MainActor [weak self] in self?.becomeFollower() } }
        )
        // Same moment, same state, different destination: the web companion
        // hears about the pass over the wire and the fleet on this Mac hears
        // about it on disk.
        localState?.write(accounts: accounts, states: states, fableFirst: isFableFirst)
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
    /// The policy itself lives in `Fetch`, shared with the headless server.
    nonisolated static func isDue(
        needsSignIn: Bool,
        retry: RetrySchedule?,
        lastAttempt: Date?,
        reason: RefreshReason,
        now: Date
    ) -> Bool {
        Fetch.isDue(needsSignIn: needsSignIn, retry: retry, lastAttempt: lastAttempt, reason: reason, now: now)
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
                Log.usage.notice("\(line)")
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
                Log.usage.notice("\(line)")
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
        if case .success = outcome, !isDemo {
            await identity.resolveIfMissing(account, vault: vault)
        }
    }

    /// Demotion, within one tick: the pass guard above stops every further
    /// request to Anthropic, and every gauge goes hollow with a verdict that
    /// says why, so no reading is left looking live after it stopped being so.
    /// Remembered in `role.json`, so the next launch starts as a follower.
    func becomeFollower() {
        enterFollowerMode(persist: true)
    }

    private func enterFollowerMode(persist: Bool) {
        if persist { remember(.follower) }
        guard !isFollowingServer else { return }
        isFollowingServer = true
        lastFollowCheck = .distantPast
        Log.role.notice("role: follower — another machine is the server; not polling Anthropic")
        for account in accounts {
            states[account.id] = AccountState.applying(
                .failure(message: Self.followingText, kind: .transient, retryAfter: nil),
                to: states[account.id]
            )
        }
    }

    /// Only the web naming this machine (or nobody) brings a follower back.
    private func leaveFollowerMode() {
        guard isFollowingServer else { return }
        isFollowingServer = false
        Log.role.notice("role: polling again — the web names this machine, or nobody, as the server")
        for account in accounts { retry[account.id] = nil; lastAttempt[account.id] = nil }
    }

    private func remember(_ stance: RoleMemory.Stance) {
        guard roleMemory?.stance != stance else { return }
        let shown = roleMemory?.shownWarnings ?? []
        roleMemory = RoleMemory(stance: stance, updatedAt: Date(), shownWarnings: shown)
        roleMemory?.save()
    }

    private func webClient() -> WebClient? {
        let key = PushKeyStore.standard.currentKey()
        if hasWebKey != (key != nil) { hasWebKey = key != nil }
        guard let key else {
            if !loggedNoKey {
                loggedNoKey = true
                Log.role.notice("role: no web key — cannot learn this Mac's role; polling as before. Connect from the ⋯ menu.")
            }
            return nil
        }
        return WebClient(key: key, machineId: MachineIdentity.id(), machine: MachineIdentity.displayName)
    }

    /// The pre-pass check. With a key: ask the web (5 s deadline) and let a
    /// live answer decide; if the web does not answer, the remembered role
    /// decides. Without a key: the remembered role decides.
    private func stillMayPoll() async -> Bool {
        guard let client = webClient() else {
            return PrePass.mayPoll(hasKey: false, live: nil, remembered: roleMemory?.stance)
        }
        let remote = try? await OAuth.firstOf(timeout: 5) { try await client.state() }
        let live = remote?.election(machineId: client.machineId)
        if let remote { apply(remote, machineId: client.machineId) }
        return PrePass.mayPoll(hasKey: true, live: live, remembered: roleMemory?.stance) && !isFollowingServer
    }

    /// One question at launch, with a short deadline. A live answer wins; no
    /// answer leaves the remembered stance in charge (see `StartupRole`).
    func settleRoleAtLaunch() async {
        guard !isDemo, let client = webClient() else { return }
        let remote = try? await OAuth.firstOf(timeout: 5) { try await client.state() }
        guard let remote else { return }
        apply(remote, machineId: client.machineId)
    }

    private func apply(_ remote: RemoteState, machineId: String) {
        self.remote = remote
        remoteFetchedAt = Date()
        followed = remote.snapshot.map(FollowedSnapshot.decode)
        let election = remote.election(machineId: machineId)
        remember(RoleMemory.stance(for: election))
        if StartupRole.mayPoll(live: election, remembered: roleMemory?.stance) {
            leaveFollowerMode()
        } else {
            enterFollowerMode(persist: false)
            followFrom(remote)
        }
    }

    /// A follower's tick: every 30 s, ask the web for the server's snapshot,
    /// hand it to the fleet's state file (the server's `updatedAt`, the server's
    /// nulls), and show any warning the server fired in the last half hour that
    /// this Mac has not shown. Never touches Anthropic or a token.
    func followIfFollowing(force: Bool = false) async {
        guard isFollowingServer, !isDemo, !isPromoting else { return }
        guard force || Date().timeIntervalSince(lastFollowCheck) >= 30 else { return }
        lastFollowCheck = Date()
        guard let client = webClient(),
              let remote = try? await OAuth.firstOf(timeout: 10, { try await client.state() })
        else { return }
        apply(remote, machineId: client.machineId)
    }

    /// Keeps the Server submenu current without anyone opening it. A follower
    /// already asks every 30 s; a server or unelected Mac asks before every
    /// poll pass anyway, so this only fills gaps, at most every 5 minutes.
    func refreshRemoteIfDue() async {
        guard !isDemo, !isPromoting else { return }
        let now = Date()
        // Every five minutes at most: the key read can touch the Keychain, and
        // the machine list changes when someone promotes, not by the minute.
        guard now.timeIntervalSince(lastBackgroundCheck) >= 300 else { return }
        // The cheap reasons to skip come first, so they never spend the slot.
        guard !isFollowingServer, now.timeIntervalSince(remoteFetchedAt) >= 300 else { return }
        lastBackgroundCheck = now
        guard let client = webClient() else { return }
        guard let remote = try? await OAuth.firstOf(timeout: 10, { try await client.state() }) else { return }
        apply(remote, machineId: client.machineId)
    }

    private func followFrom(_ remote: RemoteState) {
        guard let snapshot = remote.snapshot else { return }
        localState?.write(followingServer: snapshot, activeAccountId: ActiveAccount.signedInAccountId())
        let shown = Set(roleMemory?.shownWarnings ?? [])
        let decision = WarningReplay.decide(ServerWarning.decode(snapshot["warnings"]), shown: shown, now: Date())
        guard !decision.markSeen.isEmpty else { return }
        warner.showFromServer(decision.show)
        roleMemory = RoleMemory(
            stance: roleMemory?.stance ?? .follower, updatedAt: Date(),
            shownWarnings: (roleMemory?.shownWarnings ?? []) + Array(decision.markSeen)
        )
        roleMemory?.save()
    }

    nonisolated static let followingText = "Following server"

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
            // A follower's refresh is asking the web for the server's latest,
            // never Anthropic.
            if isFollowingServer { await followIfFollowing(force: true) }
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
        await Fetch.load(account, vault: vault)
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

    /// A promotion's failure, in the same short vocabulary as everything else
    /// on screen: never a response body, never Foundation's own sentence.
    nonisolated static func promotionMessage(for error: Error) -> String {
        if let error = error as? PromoteError { return error.errorDescription ?? "Promotion failed" }
        let text: String
        switch error {
        case let refusal as SignInRefusal: text = refusal.errorDescription ?? "Sign-in refused"
        case WebError.keyRejected: text = "Fablemeter Web rejected this Mac's key — connect again"
        case WebError.status(let code): text = "Fablemeter Web answered \(code)"
        case WebError.malformed, WebError.notServer: text = "Unexpected answer from Fablemeter Web"
        case let error as OAuthError: text = error.displayText
        case let error as ConnectError: text = error.displayText
        default: text = NetworkFailure.text(for: error) ?? NetworkFailure.genericText
        }
        return "\(text) — nothing was promoted"
    }

    nonisolated static func outcome(for error: Error) -> FetchOutcome {
        Fetch.outcome(for: error)
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
            Log.store.error("failed to save accounts: \(reason)")
        }
    }

    func addAccount() {
        guard canAddAccount else { return }
        isSigningIn = true
        signInError = nil
        Task {
            do {
                // The account is checked against every row here before it is
                // written: a second copy of an account already present is
                // refused, and its fresh token goes to the row that holds it.
                _ = try await OAuth.signIn(decide: Self.decideForNewAccount())
                let known = Set(accounts.map(\.id))
                accounts += Store.load().filter { !known.contains($0.id) }
                isSigningIn = false
                await refresh(reason: .manual)
            } catch let refusal as SignInRefusal {
                await absorb(refusal)
                signInError = Self.signInMessage(for: refusal)
                isSigningIn = false
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
        guard !isDemo, !isConnectingWeb, !isPromoting else { return }
        isConnectingWeb = true
        signInError = nil
        Task {
            do {
                try await Connect.run()
                Log.push.notice("connect: key stored")
                hasWebKey = true
                remoteFetchedAt = .distantPast
                lastBackgroundCheck = .distantPast
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
        guard !isDemo, !isSigningIn, !isPromoting else { return }
        isSigningIn = true
        signInError = nil
        let id = account.id
        Task {
            do {
                // Checked before it is written: a sign-in as some other account
                // leaves this row's credential exactly as it was.
                _ = try await OAuth.signIn(decide: Self.decideForRow(account))
                syncFromDisk(id)
                states[id]?.needsSignIn = false
                states[id]?.error = nil
                retry[id] = nil
                lastAttempt[id] = nil
                await vault.reset(id)
                isSigningIn = false
                await refresh(reason: .manual)
            } catch let refusal as SignInRefusal {
                await absorb(refusal)
                signInError = Self.signInMessage(for: refusal)
                isSigningIn = false
            } catch {
                signInError = Self.signInMessage(for: error)
                isSigningIn = false
            }
        }
    }

    // MARK: Sign-in identity
    //
    // Every interactive sign-in is judged by `SignInCheck` BEFORE anything is
    // written, inside the sign-in's `decide` step. A sign-in spends an
    // authorization code, never the stored refresh token, so refusing one costs
    // the row nothing; writing first and checking second is how a wrong-account
    // sign-in once replaced a row's only token and made the guard judge another
    // account under its letter.

    /// The rows as disk knows them, with the identity each has learned.
    nonisolated static func identityRows() -> [SignInCheck.Row] {
        let ids = AccountIdentity.load()
        return Store.load().map { SignInCheck.Row(id: $0.id, accountId: ids[$0.id], email: $0.email) }
    }

    /// A sign-in that turned out to be another row's account: its token goes to
    /// that row, never the one it was meant for, under that row's own refresh
    /// lock. A row that is mid-refresh keeps the credential it has and the
    /// token is dropped. Synchronous, because it runs inside `decide`.
    nonisolated static func route(_ signedIn: OAuth.SignedIn, to owner: UUID) -> Bool {
        let lock: RefreshLock?
        do { lock = try RefreshLock.acquire(for: owner, in: Store.directory) } catch { return false }
        defer { lock?.release() }
        do { try Store.updateRefreshToken(id: owner, to: signedIn.refreshToken) } catch { return false }
        AccountIdentity.remember(owner, accountId: signedIn.accountId)
        return true
    }

    /// `decide` for signing an existing row in again. Writes only when the
    /// verdict says the account is this row's (or the row never had an
    /// identity and this sign-in defines it); everything else throws having
    /// written nothing to the row.
    nonisolated static func decideForRow(_ target: Account) -> (OAuth.SignedIn) throws -> Void {
        let id = target.id
        let name = target.nickname
        let fallbackEmail = target.email
        return { signedIn in
            var rows = identityRows()
            if !rows.contains(where: { $0.id == id }) {
                rows.append(SignInCheck.Row(id: id, accountId: AccountIdentity.load()[id], email: fallbackEmail))
            }
            let row = rows.first(where: { $0.id == id })!
            switch SignInCheck.verdict(target: row, accountId: signedIn.accountId, email: signedIn.email, rows: rows) {
            case .match, .establish:
                try Store.mutate { stored in
                    guard let i = stored.firstIndex(where: { $0.id == id }) else { return }
                    stored[i].refreshToken = signedIn.refreshToken
                    if let email = signedIn.email, SignInCheck.isRealEmail(email) { stored[i].email = email }
                }
                AccountIdentity.remember(id, accountId: signedIn.accountId)
            case .belongsTo(let owner):
                let routed = route(signedIn, to: owner)
                let ownerName = Store.load().first(where: { $0.id == owner })?.nickname ?? "another account"
                throw SignInRefusal.otherRow(expected: name, owner: ownerName, ownerID: owner, routed: routed)
            case .mismatch:
                throw SignInRefusal.wrongAccount(expected: name, got: signedIn.email ?? "another account")
            case .unidentified:
                throw SignInRefusal.unidentified
            }
        }
    }

    /// `decide` for Add Account: a new row, unless the account is already here.
    nonisolated static func decideForNewAccount() -> (OAuth.SignedIn) throws -> Void {
        return { signedIn in
            switch SignInCheck.verdict(target: nil, accountId: signedIn.accountId, email: signedIn.email, rows: identityRows()) {
            case .establish:
                // Disk first: the token it carries exists nowhere else.
                let account = Account(email: signedIn.email ?? SignInCheck.placeholderEmail, refreshToken: signedIn.refreshToken)
                try Store.mutate { $0.append(account) }
                AccountIdentity.remember(account.id, accountId: signedIn.accountId)
            case .belongsTo(let owner):
                let routed = route(signedIn, to: owner)
                let ownerName = Store.load().first(where: { $0.id == owner })?.nickname ?? "That account"
                throw SignInRefusal.alreadyHere(owner: ownerName, ownerID: owner, routed: routed)
            case .match, .mismatch, .unidentified:
                throw SignInRefusal.unidentified
            }
        }
    }

    /// After a refusal that handed the token to another row, that row reads its
    /// new credential from disk on its next refresh.
    private func absorb(_ refusal: SignInRefusal) async {
        guard let owner = refusal.routedTo else { return }
        syncFromDisk(owner)
        await vault.reset(owner)
        states[owner]?.needsSignIn = false
        retry[owner] = nil
        lastAttempt[owner] = nil
    }

    /// The in-memory row catches up with what a sign-in just wrote to disk.
    private func syncFromDisk(_ id: UUID) {
        guard let stored = Store.load().first(where: { $0.id == id }),
              let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].email = stored.email
        accounts[i].refreshToken = stored.refreshToken
    }

    func remove(_ account: Account) {
        guard !isPromoting else { return }
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

    // MARK: What the popover and the menu bar draw

    /// The server's rows while this Mac follows and the server has reported;
    /// nil otherwise, which means "draw this Mac's own accounts".
    func followedRows(now: Date) -> [DisplayRow]? {
        guard isFollowingServer, let followed, !followed.accounts.isEmpty else { return nil }
        // The email line is this Mac's own knowledge, matched on the account
        // UUID — the payload never carries an address, and a label match could
        // put one account's address on another's numbers.
        let ids = isDemo ? [:] : AccountIdentity.load()
        return followed.accounts.map { row in
            let local = row.accountId.flatMap { id in
                accounts.first { ids[$0.id] == id }
            }
            return DisplayRow(
                id: "server:\(row.rowId)", label: row.label, nickname: row.nickname,
                email: local?.email, state: followed.state(for: row, now: now), local: nil
            )
        }
    }

    func displayRows(now: Date) -> [DisplayRow] {
        followedRows(now: now) ?? accounts.map { account in
            DisplayRow(
                id: account.id.uuidString, label: account.label, nickname: account.nickname,
                email: account.email, state: states[account.id], local: account
            )
        }
    }

    /// The footer's line: whose numbers these are and how old.
    func footerText(now: Date) -> String {
        if let promotionStep { return promotionStep }
        if isSigningIn { return "Signing in…" }
        if followedRows(now: now) != nil, let followed {
            let source = remote?.server?.machine ?? followed.machine ?? "server"
            return "From \(source) · updated \(Format.relative(followed.updatedAt, from: now))"
        }
        return "Updated \(Format.relative(lastUpdated, from: now))"
    }

    var serverMenuItems: [ServerMenuItem] {
        ServerMenuModel.items(
            hasKey: hasWebKey, remote: remote,
            machineId: isDemo ? Self.demoMachineId : MachineIdentity.id(),
            promotion: isPromoting ? (promotionStep ?? "Starting…") : nil,
            // Not `isDemo`: `promoteThisMac` refuses a demo build itself, and
            // the render must show the item as the real menu does.
            busy: isSigningIn || isConnectingWeb
        )
    }

    // MARK: Promotion

    /// "Make This Mac the Server": every account signs in again here, one at a
    /// time, then — only then — the web is told. See `PromoteSequence`.
    func promoteThisMac() {
        guard !isDemo, !isPromoting, !isSigningIn, !isConnectingWeb, let client = webClient() else { return }
        isPromoting = true
        promotionStep = nil
        signInError = nil
        promoteTask = Task { [weak self] in
            await self?.runPromotion(client: client)
            self?.isPromoting = false
            self?.promotionStep = nil
            self?.promoteTask = nil
        }
    }

    func cancelPromotion() {
        promoteTask?.cancel()
    }

    private func runPromotion(client: WebClient) async {
        // A pass already under way finishes first; `refresh` refuses to start
        // another while `isPromoting` is set, so from here on nothing on this
        // Mac refreshes a token but the sign-ins below.
        var waited = 0
        while isPassRunning && waited < 1200 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        // Still running after two minutes: stop here rather than sign in
        // alongside it. Nothing has been touched yet.
        guard !isPassRunning else {
            Log.role.notice("role: promotion refused — a refresh is still running")
            signInError = PromoteError.passBusy.errorDescription
            return
        }
        let before = roleMemory?.stance
        let renamed = await inheritServerNames(client: client)
        let outcome = await PromoteSequence.run(
            accounts: accounts,
            progress: { [weak self] index, count, account in
                await self?.showStep(PromoteSequence.stepText(nickname: account.nickname, index: index, count: count))
            },
            signIn: { [weak self] account in
                guard let self else { throw CancellationError() }
                try await self.reSign(account)
            },
            promote: { _ = try await client.promote() },
            describe: { AppState.promotionMessage(for: $0) }
        )
        let after = PromoteSequence.stanceAfter(outcome, before: before)
        switch outcome {
        case .promoted:
            remember(after ?? .server)
            Log.role.notice("role: promoted — this Mac is the server")
            leaveFollowerMode()
            promotionStep = nil
            isPromoting = false
            remoteFetchedAt = .distantPast
            lastBackgroundCheck = .distantPast
            await refreshRemoteIfDue()
            await refresh(reason: .manual)
        case .cancelled:
            restoreNames(renamed)
            Log.role.notice("role: promotion cancelled — nothing was promoted")
        case .failed(let message):
            restoreNames(renamed)
            // The reason goes to the banner only: it can name an address, and
            // the log has never carried one.
            Log.role.notice("role: promotion failed — nothing was promoted")
            signInError = message
        }
    }

    private func showStep(_ text: String) { promotionStep = text }

    /// One account, signed in again on this Mac. The account's cross-process
    /// refresh lock is held for the whole of it, so no refresh — this app's or
    /// any other process's — can spend the account's token while its
    /// replacement is being issued. The fresh token is on disk the instant it
    /// exists, before anything else is awaited.
    private func reSign(_ account: Account) async throws {
        let lock: RefreshLock?
        do {
            lock = try RefreshLock.acquire(for: account.id, in: Store.directory)
        } catch {
            throw PromoteError.busy(account.nickname)
        }
        defer { lock?.release() }
        await vault.forget(account.id)
        let id = account.id
        do {
            // Judged before anything is written: the wrong account leaves this
            // row's token, address and account id exactly as they were.
            _ = try await OAuth.signIn(decide: Self.decideForRow(account))
        } catch let refusal as SignInRefusal {
            await absorb(refusal)
            throw refusal
        }
        syncFromDisk(id)
        await vault.reset(id)
        states[id]?.needsSignIn = false
        retry[id] = nil
        lastAttempt[id] = nil
    }

    /// Before promoting away from another server, take its names for the same
    /// accounts — matched on the Anthropic account UUID, never the label — so
    /// the letters agents already pass as `--account` keep meaning the same
    /// accounts. A label another account here already uses is left alone.
    private func inheritServerNames(client: WebClient) async -> [(id: UUID, nickname: String, label: String)] {
        guard let fresh = try? await OAuth.firstOf(timeout: 10, { try await client.state() }) else { return [] }
        remote = fresh
        remoteFetchedAt = Date()
        guard case .other = fresh.election(machineId: client.machineId),
              let rows = fresh.snapshot?["accounts"] as? [[String: Any]] else { return [] }
        var before: [(id: UUID, nickname: String, label: String)] = []
        let ids = AccountIdentity.load()
        for row in rows {
            guard let accountId = AccountIdentity.normalize(row["accountId"] as? String),
                  let local = accounts.first(where: { ids[$0.id] == accountId }) else { continue }
            let original = (id: local.id, nickname: local.nickname, label: local.label)
            var changed = false
            if let nickname = row["nickname"] as? String, nickname != local.nickname {
                setNickname(nickname, for: local)
                changed = true
            }
            if let label = row["label"] as? String, label != local.label {
                let taken = Set(accounts.filter { $0.id != local.id }.map(\.label))
                if PromoteLabels.isFree(label, taken: taken) {
                    setLabel(label, for: local)
                    changed = true
                }
            }
            if changed { before.append(original) }
        }
        return before
    }

    /// A promotion that did not happen leaves this Mac named as it was. In
    /// reverse, so a label freed by one row is free again for the row that had
    /// it; only labels this promotion itself assigned are ever in play.
    private func restoreNames(_ originals: [(id: UUID, nickname: String, label: String)]) {
        for original in originals.reversed() {
            guard let account = accounts.first(where: { $0.id == original.id }) else { continue }
            if account.label != original.label { setLabel(original.label, for: account) }
            if let current = accounts.first(where: { $0.id == original.id }), current.nickname != original.nickname {
                setNickname(original.nickname, for: current)
            }
        }
    }

    nonisolated static let demoMachineId = "DEMO-THIS-MAC"

    /// `--render-popover` only: the server/follower states worth eyeballing,
    /// seeded with fixture machines and a fixture server snapshot. Refused
    /// outside a demo build, so nothing real can be dressed up as one of these.
    enum DemoRole: String, CaseIterable {
        case unelected
        case server
        case following
        case noKey = "no-key"
        case promoting
    }

    func applyDemoRole(_ role: DemoRole, now: Date = Date()) {
        guard isDemo else { return }
        let me = Self.demoMachineId
        let fleet: [(String, String)] = [(me, "Izu's MacBook Pro"), ("DEMO-FLY", "fly-iconic"), ("DEMO-MINI", "Studio Mac mini")]
        func iso(_ offset: TimeInterval) -> String { ISODate.string(now.addingTimeInterval(offset)) }
        func bucket(_ percent: Any, _ reset: TimeInterval?) -> [String: Any] {
            ["percent": percent, "resetsAt": reset.map { iso($0) } ?? NSNull()]
        }
        let snapshot: [String: Any] = [
            "updatedAt": iso(-120), "machine": "fly-iconic", "machineId": "DEMO-FLY",
            "accounts": [
                ["id": "S1", "label": "P", "nickname": "Personal", "headroom": 71, "verdict": "Available", "isStale": false,
                 "buckets": ["fiveHour": bucket(29, 4000), "weekly": bucket(10, 300_000), "fable": bucket(3, 300_000)]],
                ["id": "S2", "label": "C", "nickname": "Charm", "headroom": 0, "verdict": "Blocked", "isStale": false,
                 "buckets": ["fiveHour": bucket(0, nil), "weekly": bucket(100, 200_000), "fable": bucket(100, 200_000)]],
                ["id": "S3", "label": "I", "nickname": "Iconic", "headroom": 0, "verdict": "Blocked", "isStale": false,
                 "buckets": ["fiveHour": bucket(NSNull(), nil), "weekly": bucket(100, 200_000), "fable": bucket(100, 200_000)]],
            ] as [[String: Any]],
        ]
        func remoteState(server: String?, withSnapshot: Bool) -> RemoteState? {
            var json: [String: Any] = [
                "machines": fleet.map { ["machineId": $0.0, "machine": $0.1, "lastSeen": iso(-60), "role": "server"] },
            ]
            if let server {
                json["server"] = ["machineId": server, "machine": fleet.first { $0.0 == server }?.1 ?? server, "since": iso(-3600)]
                json["you"] = ["role": server == me ? "server" : "follower"]
            }
            if withSnapshot { json["snapshot"] = snapshot }
            return (try? JSONSerialization.data(withJSONObject: json)).flatMap(RemoteState.decode)
        }
        isFollowingServer = false
        followed = nil
        isPromoting = false
        promotionStep = nil
        switch role {
        case .noKey:
            hasWebKey = false
            remote = nil
        case .unelected:
            hasWebKey = true
            remote = remoteState(server: nil, withSnapshot: false)
        case .server:
            hasWebKey = true
            remote = remoteState(server: me, withSnapshot: false)
        case .following, .promoting:
            hasWebKey = true
            remote = remoteState(server: "DEMO-FLY", withSnapshot: true)
            followed = remote?.snapshot.map(FollowedSnapshot.decode)
            isFollowingServer = true
            if role == .promoting {
                isPromoting = true
                promotionStep = PromoteSequence.stepText(nickname: "Charm", index: 2, count: 3)
            }
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
            Log.store.error("login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
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

/// Why a promotion stopped, in the app's short vocabulary. Nothing here is a
/// response body.
enum PromoteError: LocalizedError {
    case busy(String)
    /// A poll pass was still running after the two-minute wait.
    case passBusy

    var errorDescription: String? {
        switch self {
        case .busy(let name): return "\(name) is being refreshed elsewhere — try again"
        case .passBusy: return "A refresh is still running — try again, nothing was promoted"
        }
    }
}

/// Why an interactive sign-in wrote nothing to the row it was meant for. The
/// row keeps the credential it had: a sign-in spends an authorization code,
/// not the stored refresh token.
enum SignInRefusal: LocalizedError, Equatable {
    /// An account no row here holds.
    case wrongAccount(expected: String, got: String)
    /// Another row's account; its token went to that row when `routed`.
    case otherRow(expected: String, owner: String, ownerID: UUID, routed: Bool)
    /// Add Account with an account already here; refreshed in place when `routed`.
    case alreadyHere(owner: String, ownerID: UUID, routed: Bool)
    /// Neither an account id nor a real address came back.
    case unidentified

    var routedTo: UUID? {
        switch self {
        case .otherRow(_, _, let id, true), .alreadyHere(_, let id, true): return id
        default: return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .wrongAccount(let expected, let got):
            return "That was \(got), not \(expected) — sign in as \(expected)"
        case .otherRow(let expected, let owner, _, _):
            return "That was \(owner), not \(expected) — sign in as \(expected)"
        case .alreadyHere(let owner, _, let routed):
            return routed ? "\(owner) is already here — its sign-in was refreshed" : "\(owner) is already here"
        case .unidentified:
            return "Could not identify the account — nothing was saved"
        }
    }
}

/// One row as the popover and the menu bar draw it: this Mac's own account, or
/// — while following — a row the server measured. `local` is nil for the
/// latter, which is what makes a row read-only: nothing on a server row can
/// rename, reorder, reconnect or sign out an account this Mac does not hold.
struct DisplayRow: Identifiable {
    let id: String
    let label: String
    let nickname: String
    let email: String?
    let state: AccountState?
    let local: Account?

    var character: Character { label.first ?? "?" }
}
