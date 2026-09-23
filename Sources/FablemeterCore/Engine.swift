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
    private var shown = Set<String>()
    private var states: [UUID: AccountState] = [:]
    private var retry: [UUID: RetrySchedule] = [:]
    private var lastAttempt: [UUID: Date] = [:]
    private var remote: RemoteState?
    private var lastRemoteCheck: Date = .distantPast
    private var isServer = true
    private var loggedRole: Bool?
    /// Set by the push completion on a 409, read before every request.
    private let demoted = Locked<Bool>(initialState: false)

    init(settings: Settings = .fromEnvironment(),
         machineId: String = MachineIdentity.id(),
         machine: String = MachineIdentity.displayName) {
        self.settings = settings
        self.machineId = machineId
        self.machine = machine
    }

    /// Forever. One tick every `PollPolicy.tick` seconds.
    func run() async {
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
            // it at once, and look at the web on this very tick.
            isServer = Self.nextIsServer(current: isServer, demoted: true, remote: nil, machineId: machineId)
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
        noteRole()
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
        let activeLabel = ActiveAccount.match(email: ActiveAccount.signedInEmail(), accounts: Store.load())
            .flatMap { id in Store.load().first { $0.id == id } }
            .map { String($0.character) }
        localState.write(followingServer: snapshot, activeLabel: activeLabel)
        let decision = WarningReplay.decide(ServerWarning.decode(snapshot["warnings"]), shown: shown, now: now)
        shown.formUnion(decision.markSeen)
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
            try LocalState.data(accounts: accounts, states: states, fableFirst: fableFirst, activeID: activeID)
        }
    }

    func write(followingServer snapshot: [String: Any], activeLabel: String?) {
        write {
            try JSONSerialization.data(
                withJSONObject: LocalState.body(followingServer: snapshot, activeLabel: activeLabel),
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
