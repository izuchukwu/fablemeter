import AppKit
import SwiftUI

struct AccountState {
    var snapshot: UsageSnapshot?
    var error: String?
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
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    var canAddAccount: Bool { !isDemo && accounts.count < Store.maxAccounts && !isSigningIn }

    /// What the status item draws, one cell per account.
    var barCells: [BarCell] {
        accounts.map { account in
            let state = states[account.id]
            return BarCell(
                character: account.character,
                headroom: state?.snapshot?.headroom,
                isError: state?.error != nil
            )
        }
    }

    func state(for account: Account) -> AccountState? { states[account.id] }

    // MARK: Refreshing

    func refreshAll() async {
        guard !isDemo else { return }
        guard !accounts.isEmpty else {
            lastUpdated = Date()
            return
        }
        isRefreshing = true
        let snapshot = accounts
        let vault = self.vault
        let results = await withTaskGroup(of: (UUID, AccountState).self) { group in
            for account in snapshot {
                group.addTask { (account.id, await Self.load(account, vault: vault)) }
            }
            var out: [UUID: AccountState] = [:]
            for await (id, state) in group { out[id] = state }
            return out
        }
        for (id, state) in results { states[id] = state }
        states = states.filter { id, _ in snapshot.contains { $0.id == id } }
        lastUpdated = Date()
        isRefreshing = false
    }

    func manualRefresh() {
        guard Date().timeIntervalSince(lastManualRefresh) >= 5 else { return }
        lastManualRefresh = Date()
        Task { await refreshAll() }
    }

    /// Refresh when the popover opens, but don't hammer it.
    func refreshIfStale() {
        guard !isDemo else { return }
        if let last = lastUpdated, Date().timeIntervalSince(last) < 5 { return }
        Task { await refreshAll() }
    }

    private static func load(_ account: Account, vault: TokenVault) async -> AccountState {
        do {
            let token = try await vault.accessToken(for: account)
            do {
                return AccountState(snapshot: try await UsageClient.fetch(accessToken: token), error: nil)
            } catch UsageError.unauthorized {
                let fresh = try await vault.accessToken(for: account, force: true)
                return AccountState(snapshot: try await UsageClient.fetch(accessToken: fresh), error: nil)
            }
        } catch let error as UsageError {
            return AccountState(error: error.errorDescription)
        } catch let error as OAuthError {
            return AccountState(error: error.errorDescription)
        } catch {
            return AccountState(error: error.localizedDescription)
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
                await refreshAll()
            } catch {
                signInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isSigningIn = false
            }
        }
    }

    func remove(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        states[account.id] = nil
        guard !isDemo else { return }
        Store.save(accounts)
        Task { await vault.forget(account.id) }
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

    /// `--demo`: three in-memory accounts at headroom 85 / 22 / 8 so every visual
    /// tier (monochrome, orange, red) can be inspected without signing in.
    private static func demoData() -> (accounts: [Account], states: [UUID: AccountState]) {
        let specs: [(label: String, nickname: String, email: String, five: Double, weekly: Double, fable: Double)] = [
            ("P", "Personal", "izu@personal.com", 15, 5, 10),
            ("W", "Work", "izu@work.example", 78, 20, 40),
            ("T", "Team", "izu@team.example", 92, 30, 50)
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
            snap.scoped = [UsageBucket(
                id: "scoped:Fable", label: "Fable", percent: spec.fable,
                resetsAt: Date().addingTimeInterval(273_600)
            )]
            accounts.append(account)
            states[account.id] = AccountState(snapshot: snap, error: nil)
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
