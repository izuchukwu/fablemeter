import Foundation

// MARK: - Headless engine

/// The menu bar app's poll loop without the menu bar: the same `Fetch`
/// policy, the same `TokenVault`, the same backoff, the same push and local
/// state — plus the role check that decides whether this machine may talk to
/// Anthropic at all.
///
/// Everything mutable here is touched only from the one task `run()` drives,
/// in order; the single exception is the 409 flag the push completion sets,
/// which is locked.
final class Engine: @unchecked Sendable {
    struct Settings {
        var fableFirst = true
        var warn = WarnSettings()
        /// How often a follower asks the web for the server's snapshot, and
        /// how often a server checks it has not been demoted.
        var followInterval: TimeInterval = 30
        var serverHeartbeat: TimeInterval = 60

        static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Settings {
            func flag(_ name: String) -> Bool? {
                guard let raw = env[name]?.lowercased() else { return nil }
                if ["0", "false", "no", "off"].contains(raw) { return false }
                if ["1", "true", "yes", "on"].contains(raw) { return true }
                return nil
            }
            var s = Settings()
            s.fableFirst = flag("FABLEMETER_FABLE_FIRST") ?? true
            s.warn.at75 = flag("FABLEMETER_WARN_75") ?? true
            s.warn.at90 = flag("FABLEMETER_WARN_90") ?? true
            s.warn.at95 = flag("FABLEMETER_WARN_95") ?? true
            s.warn.fastBurn = flag("FABLEMETER_WARN_FAST_BURN") ?? true
            return s
        }
    }

    let settings: Settings
    let machineId: String
    let machine: String

    private let vault = TokenVault()
    private let pusher = Pusher()
    private let ledger = WarningLedger()
    private let localState = LocalStateFile()
    private var fired = Set<String>()
    private var shown: Set<String>
    private let identity = IdentityResolver()
    private var states: [UUID: AccountState] = [:]
    private var retry: [UUID: RetrySchedule] = [:]
    private var lastAttempt: [UUID: Date] = [:]
    private var remote: RemoteState?
    private var lastRemoteCheck: Date = .distantPast
    /// Seeded from `role.json`, never assumed: a follower that restarts while
    /// the web is unreachable must stay a follower.
    private var isServer: Bool
    private var stance: RoleMemory.Stance?
    private var loggedRole: Bool?
    /// Set by the push completion on a 409, read before every request.
    private let demoted = Locked<Bool>(initialState: false)

    init(settings: Settings = .fromEnvironment(),
         machineId: String = MachineIdentity.id(),
         machine: String = MachineIdentity.displayName) {
        self.settings = settings
        self.machineId = machineId
        self.machine = machine
        let memory = RoleMemory.load()
        stance = memory?.stance
        isServer = StartupRole.mayPoll(live: nil, remembered: memory?.stance)
        shown = Set(memory?.shownWarnings ?? [])
    }

    /// Forever. One tick every `PollPolicy.tick` seconds.
    func run() async {
        // One daemon per data directory, for the process lifetime. `promote`
        // takes the same lock, so it can never rewrite accounts.json while a
        // running daemon is rotating a token in it; a daemon started mid-promote
        // waits here until the sign-ins are saved.
        let daemonLock = DaemonLock.acquire(in: Store.directory, wait: true, onWait: {
            Log.role.notice("engine: another fablemeter process holds the data directory (promote running?) — waiting")
        })
        defer { daemonLock?.release() }
        Log.role.notice("engine: started machine=\(machine) id=\(machineId)")
        while !Task.isCancelled {
            await tick(now: Date())
            try? await Task.sleep(nanoseconds: PollPolicy.tickNanoseconds)
        }
    }

    func tick(now: Date) async {
        await refreshRole(now: now)
        if isServer {
            await pollPass()
        } else {
            follow(now: now)
        }
    }

    // MARK: Role

    private func refreshRole(now: Date) async {
        let wasDemoted = demoted.withLock { flag in defer { flag = false }; return flag }
        if wasDemoted {
            // The web refused our push: someone else is the server. Believe
            // it at once, remember it across restarts, and look at the web on
            // this very tick.
            isServer = Self.nextIsServer(current: isServer, demoted: true, remote: nil, machineId: machineId)
            remember(.follower)
            lastRemoteCheck = .distantPast
        }
        let interval = isServer ? settings.serverHeartbeat : settings.followInterval
        guard now.timeIntervalSince(lastRemoteCheck) >= interval else { return }
        lastRemoteCheck = now
        guard let key = PushKeyStore.standard.currentKey() else {
            remote = nil
            noteRole()
            return
        }
        let client = WebClient(key: key, machineId: machineId, machine: machine)
        do {
            remote = try await client.state()
        } catch WebError.keyRejected {
            Log.role.notice("engine: machine key rejected — run `fablemeter-server connect`")
            remote = nil
        } catch {
            // Web unreachable: keep the last decision (see RoleDecision).
            remote = nil
        }
        isServer = Self.nextIsServer(current: isServer, demoted: false, remote: remote, machineId: machineId)
        if let remote {
            remember(RoleMemory.stance(for: remote.election(machineId: machineId)))
        } else if wasDemoted {
            remember(.follower)
        }
        noteRole()
    }

    private func stillMayPoll() async -> Bool {
        guard let key = PushKeyStore.standard.currentKey() else {
            return PrePass.mayPoll(hasKey: false, live: nil, remembered: stance)
        }
        let now = Date()
        if remote == nil || now.timeIntervalSince(lastRemoteCheck) > 30 {
            let client = WebClient(key: key, machineId: machineId, machine: machine)
            lastRemoteCheck = now
            remote = try? await client.state()
            if let remote { remember(RoleMemory.stance(for: remote.election(machineId: machineId))) }
        }
        let live = remote?.election(machineId: machineId)
        let may = PrePass.mayPoll(hasKey: true, live: live, remembered: stance)
        if !may, isServer {
            isServer = false
            noteRole()
        }
        return may
    }

    private func remember(_ next: RoleMemory.Stance) {
        guard next != stance else { return }
        stance = next
        persistMemory()
    }

    private func persistMemory() {
        RoleMemory(stance: stance ?? .unelected, updatedAt: Date(), shownWarnings: Array(shown)).save()
    }

    /// The whole role transition, pure. A 409 demotes at once, and only the
    /// web naming this machine again (or nobody at all) brings it back; an
    /// unreachable web never promotes anything.
    static func nextIsServer(current: Bool, demoted: Bool, remote: RemoteState?, machineId: String) -> Bool {
        RoleDecision.shouldPoll(remote: remote, machineId: machineId, lastDecision: demoted ? false : current)
    }

    private func noteRole() {
        guard loggedRole != isServer else { return }
        loggedRole = isServer
        Log.role.notice(isServer ? "role: server — polling Anthropic" : "role: follower — reading the server's snapshot")
    }

    // MARK: Server

    private func pollPass() async {
        // Disk is the authority on accounts, so a `promote` that added one a
        // moment ago is polled on this pass without a restart.
        let accounts = Store.load()
        guard !accounts.isEmpty else { return }
        let now = Date()
        let due = accounts.filter { account in
            Fetch.isDue(
                needsSignIn: states[account.id]?.needsSignIn == true,
                retry: retry[account.id],
                lastAttempt: lastAttempt[account.id],
                reason: .scheduled,
                now: now
            )
        }
        guard !due.isEmpty else { return }
        // Still the server? Once per pass, before anything reaches Anthropic
        // (see `PrePass`). Reuses a /api/state answer under 30 s old — the
        // heartbeat usually just asked — so a server stays near 60-70 reads/hr.
        guard await stillMayPoll() else { return }
        for (index, account) in due.enumerated() {
            // Demotion is honoured between accounts, not only between passes.
            if demoted.withLock({ $0 }) { return }
            if index > 0 {
                try? await Task.sleep(nanoseconds: UInt64(PollPolicy.stagger * 1_000_000_000))
            }
            await fetch(account)
        }
        let flag = demoted
        pusher.push(
            accounts: accounts, states: states, fableFirst: settings.fableFirst,
            warnings: ledger.recent(),
            onNotServer: { flag.withLock { $0 = true } }
        )
        localState.write(accounts: accounts, states: states, fableFirst: settings.fableFirst)
    }

    private func fetch(_ account: Account) async {
        lastAttempt[account.id] = Date()
        let outcome = await Fetch.load(account, vault: vault)
        let previous = states[account.id]
        var schedule = retry[account.id] ?? RetrySchedule()
        switch outcome {
        case .success(let snapshot):
            schedule.recordSuccess()
            Log.usage.notice(UsageLog.line(label: account.character, snapshot: snapshot))
            await identity.resolveIfMissing(account, vault: vault)
            let warnings = WarnPolicy.assess(
                name: account.nickname, label: account.character,
                previous: previous?.snapshot, current: snapshot,
                now: Date(), settings: settings.warn, fired: fired
            )
            if !warnings.isEmpty {
                fired.formUnion(warnings.map(\.key))
                ledger.record(warnings)
                Task.detached {
                    for warning in warnings { await Slack.post(title: warning.title, body: warning.body) }
                }
            }
        case .failure(let message, let kind, let retryAfter):
            schedule.recordFailure(kind, retryAfter: retryAfter)
            Log.usage.notice(UsageLog.failureLine(
                label: account.character, message: message, kind: kind, attempt: schedule.failures
            ))
        case .needsSignIn:
            schedule = RetrySchedule()
            Log.usage.notice("usage [\(account.character)] needs sign-in — run `fablemeter-server promote`")
        }
        states[account.id] = AccountState.applying(outcome, to: previous)
        retry[account.id] = schedule
    }

    // MARK: Follower

    private func follow(now: Date) {
        guard let snapshot = remote?.snapshot else { return }
        localState.write(followingServer: snapshot, activeAccountId: ActiveAccount.signedInAccountId())
        let decision = WarningReplay.decide(ServerWarning.decode(snapshot["warnings"]), shown: shown, now: now)
        if !decision.markSeen.isEmpty {
            shown.formUnion(decision.markSeen)
            persistMemory()
        }
        // Headless has no notification centre; the log is where a follower
        // says it. The menu bar app's follower mode turns these into
        // notifications.
        for warning in decision.show {
            Log.usage.notice("warning from server: \(warning.title) — \(warning.body)")
        }
    }
}

/// `LocalStateWriter` without the main actor, for the headless engine.
final class LocalStateFile: @unchecked Sendable {
    private var loggedFailure = false

    func write(accounts: [Account], states: [UUID: AccountState], fableFirst: Bool) {
        let activeID = ActiveAccount.match(email: ActiveAccount.signedInEmail(), accounts: accounts)
        write {
            try LocalState.data(
                accounts: accounts, states: states, fableFirst: fableFirst, activeID: activeID,
                accountIds: AccountIdentity.load()
            )
        }
    }

    func write(followingServer snapshot: [String: Any], activeAccountId: String?) {
        write {
            try JSONSerialization.data(
                withJSONObject: LocalState.body(followingServer: snapshot, activeAccountId: activeAccountId),
                options: [.sortedKeys, .prettyPrinted]
            )
        }
    }

    private func write(_ make: () throws -> Data) {
        do {
            let payload = try make()
            try FileManager.default.createDirectory(
                at: LocalState.directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            try AtomicFile.write(payload, to: LocalState.file, mode: 0o644)
        } catch {
            if !loggedFailure {
                loggedFailure = true
                Log.store.notice("local state: write failed, disabled for this run")
            }
        }
    }
}

/// One process at a time per data directory: the daemon for its lifetime,
/// `promote` for the length of its sign-ins. `flock`, so a holder that dies
/// releases it and no stale lock file can wedge anything.
final class DaemonLock: @unchecked Sendable {
    private var descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }

    enum Outcome { case acquired(DaemonLock), busy, unavailable }

    static func tryAcquire(in directory: URL) -> Outcome {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let fd = open(directory.appendingPathComponent(".daemon.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return .unavailable }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return .acquired(DaemonLock(descriptor: fd)) }
        let busy = errno == EWOULDBLOCK
        close(fd)
        return busy ? .busy : .unavailable
    }

    /// Blocking form for the daemon. `nil` only when locking is impossible
    /// (unwritable directory) — which must not stop a server measuring.
    static func acquire(in directory: URL, wait: Bool, onWait: () -> Void) -> DaemonLock? {
        switch tryAcquire(in: directory) {
        case .acquired(let lock): return lock
        case .unavailable: return nil
        case .busy:
            guard wait else { return nil }
            onWait()
            let fd = open(directory.appendingPathComponent(".daemon.lock").path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX) == 0 else { return nil }
            return DaemonLock(descriptor: fd)
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
