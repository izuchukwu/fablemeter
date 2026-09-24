import Foundation

// MARK: - Drawing the server's numbers

/// One account as the SERVER measured it, rebuilt from the push payload a
/// follower reads back from the web.
///
/// The payload carries buckets, not a verdict to trust: a follower rebuilds a
/// `UsageSnapshot` from them and lets the same `headroom(fableFirst:)` the
/// server uses decide the gauge, under THIS Mac's Fable-first setting. A null
/// percent stays nil all the way through, so a reading the server never got
/// draws as no data here too, never as zero.
struct FollowedAccount {
    /// The server's own id for the row. Only used to keep rows apart.
    let rowId: String
    let label: String
    let nickname: String
    /// The Anthropic account UUID, when the server knows it.
    let accountId: String?
    let snapshot: UsageSnapshot
    /// The server's own newest fetch for this account failed.
    let serverStale: Bool

    var character: Character { label.first ?? "?" }
}

struct FollowedSnapshot {
    let accounts: [FollowedAccount]
    /// When the SERVER measured, not when this Mac copied. Staleness is judged
    /// from this and nothing else.
    let updatedAt: Date?
    /// The machine that measured, when the payload names it.
    let machine: String?
    /// False when the snapshot is not the named server's own reading (see
    /// `SnapshotSource`): its numbers are shown, but hollow, never as live.
    var fromServer = true

    /// The web page's own threshold: past this, the numbers are history and the
    /// gauge goes hollow rather than looking live.
    static let staleAfter: TimeInterval = 12 * 60
    static let staleText = "Stale"

    static func decode(_ payload: [String: Any]) -> FollowedSnapshot {
        let rows = (payload["accounts"] as? [[String: Any]]) ?? []
        let updatedAt = ISODate.parse(payload["updatedAt"] as? String)
        let accounts = rows.compactMap { row -> FollowedAccount? in
            guard let label = row["label"] as? String, !label.isEmpty else { return nil }
            let buckets = (row["buckets"] as? [String: Any]) ?? [:]
            func bucket(_ key: String, id: String, title: String) -> UsageBucket? {
                guard let raw = buckets[key] as? [String: Any] else { return nil }
                // A JSON null decodes to NSNull, which no numeric cast accepts —
                // so null stays nil, and only a number becomes a reading.
                let percent = FollowedSnapshot.number(raw["percent"])
                return UsageBucket(
                    id: id, label: title, percent: percent,
                    resetsAt: ISODate.parse(raw["resetsAt"] as? String)
                )
            }
            var snap = UsageSnapshot()
            snap.fiveHour = bucket("fiveHour", id: "session", title: "5-hour")
            snap.weekly = bucket("weekly", id: "weekly", title: "Weekly")
            snap.scoped = bucket("fable", id: "scoped:Fable", title: "Fable").map { [$0] } ?? []
            snap.fetchedAt = updatedAt ?? Date()
            return FollowedAccount(
                rowId: (row["id"] as? String) ?? label,
                label: label,
                nickname: (row["nickname"] as? String) ?? label,
                accountId: AccountIdentity.normalize(row["accountId"] as? String),
                snapshot: snap,
                serverStale: (row["isStale"] as? Bool) ?? false
            )
        }
        return FollowedSnapshot(accounts: accounts, updatedAt: updatedAt, machine: payload["machine"] as? String)
    }

    /// A JSON number as Foundation hands it over on either platform: Darwin
    /// bridges to NSNumber, Linux may hand back Swift natives. NSNull matches
    /// none of these, so a null reading stays nil.
    static func number(_ any: Any?) -> Double? {
        // A JSON `true` arrives on Apple platforms as an NSNumber that `as
        // Double` happily bridges to 1.0. A boolean is not a reading.
        if isBoolean(any) { return nil }
        switch any {
        case let value as Double: return value.isFinite ? value : nil
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue.isFinite ? value.doubleValue : nil
        default: return nil
        }
    }

    /// True for a JSON boolean on either platform: a Swift `Bool` (Linux),
    /// or Foundation's boolean NSNumber (Apple, where `true` also bridges to
    /// `Int` and `Double`). A JSON `0` or `1` is a number, never a boolean.
    static func isBoolean(_ any: Any?) -> Bool {
        guard let any else { return false }
        if type(of: any) == Bool.self { return true }
        #if canImport(Darwin)
        if let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return true }
        #else
        if let n = any as? NSNumber {
            let kind = String(cString: n.objCType)
            return kind == "c" || kind == "B"
        }
        #endif
        return false
    }

    /// What a follower draws from one `/api/state` answer.
    static func followed(from remote: RemoteState) -> FollowedSnapshot? {
        guard let payload = remote.snapshot else { return nil }
        var followed = decode(payload)
        followed.fromServer = remote.snapshotIsServers
        return followed
    }

    func isOld(now: Date) -> Bool {
        guard let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) > Self.staleAfter
    }

    /// What a row draws. The server's numbers always; hollow, with one word
    /// saying so, when the server's own fetch failed, the snapshot is old, or
    /// it is not the server's own reading at all.
    func state(for account: FollowedAccount, now: Date) -> AccountState {
        AccountState(
            snapshot: account.snapshot,
            error: !fromServer || account.serverStale || isOld(now: now) ? Self.staleText : nil,
            needsSignIn: false
        )
    }
}

// MARK: - The Server submenu

/// What the ⋯ menu's Server submenu lists. Built from what the background
/// poll already knows, never fetched when the menu opens. Pure, so the
/// selftest pins which items exist and which one can be clicked.
///
/// Only one thing here is ever actionable: making THIS machine the server.
/// There is deliberately no way to name another machine — promotion is a
/// person signing in on the machine that will spend the tokens.
enum ServerMenuItem: Equatable {
    /// A line of text that cannot be clicked.
    case caption(String)
    /// A known machine, informational only; `isServer` draws the checkmark.
    case machine(title: String, isServer: Bool)
    case divider
    case makeThisMacServer(enabled: Bool)
    case connect
    case cancelPromotion
}

enum ServerMenuModel {
    static let unelectedText = "No server — each Mac polls for itself"
    static let unreachedText = "Web not reached yet"
    static let notConnectedText = "Not connected to Fablemeter Web"

    /// - Parameters:
    ///   - promotion: the step being shown while a promotion runs, e.g.
    ///     "Signing into Personal (1 of 3)…"; nil when none is running.
    ///   - busy: something else holds the sign-in (an account being added or
    ///     reconnected), so a promotion cannot start now.
    static func items(
        hasKey: Bool, remote: RemoteState?, machineId: String,
        promotion: String?, busy: Bool
    ) -> [ServerMenuItem] {
        if let promotion { return [.caption(promotion), .divider, .cancelPromotion] }
        guard hasKey else { return [.caption(notConnectedText), .connect] }
        guard let remote else {
            return [.caption(unreachedText), .divider, .makeThisMacServer(enabled: !busy)]
        }
        let election = remote.election(machineId: machineId)
        var items: [ServerMenuItem] = []
        if case .unelected = election { items.append(.caption(unelectedText)) }
        items += machineRows(remote: remote, machineId: machineId)
        if case .thisMachine = election { return items }
        return items + [.divider, .makeThisMacServer(enabled: !busy)]
    }

    /// The server first, then this Mac, then everyone else in the web's order.
    /// The server is listed even if it has not checked in for a day, so the
    /// checkmark is never missing from the list it describes.
    static func machineRows(remote: RemoteState, machineId: String) -> [ServerMenuItem] {
        let serverId = remote.server?.machineId
        var rows = remote.machines.map { ($0.machineId, $0.machine) }
        if let server = remote.server, !rows.contains(where: { $0.0 == server.machineId }) {
            rows.append((server.machineId, server.machine))
        }
        func rank(_ id: String) -> Int { id == serverId ? 0 : id == machineId ? 1 : 2 }
        let ordered = rows.enumerated().sorted {
            (rank($0.element.0), $0.offset) < (rank($1.element.0), $1.offset)
        }.map(\.element)
        return ordered.map { id, name in
            .machine(title: id == machineId ? "\(name) (This Mac)" : name, isServer: id == serverId)
        }
    }
}

// MARK: - Promoting this Mac

/// Sign every account in again on this machine, one at a time, then — only
/// then — tell the web this machine is the server.
///
/// A cancel or a failure anywhere before the last sign-in stops everything:
/// the web is never told, so the machine stays whatever it was. Accounts that
/// were already re-signed keep their fresh sign-ins, which bricks nothing — a
/// fresh sign-in is this machine's own token lineage.
enum PromoteSequence {
    enum Outcome: Equatable {
        case promoted
        case cancelled
        case failed(String)
    }

    static let noAccountsText = "No accounts to sign in"

    static func run(
        accounts: [Account],
        progress: @Sendable (_ index: Int, _ count: Int, _ account: Account) async -> Void,
        signIn: @Sendable (Account) async throws -> Void,
        promote: @Sendable () async throws -> Void,
        describe: @Sendable (Error) -> String
    ) async -> Outcome {
        guard !accounts.isEmpty else { return .failed(noAccountsText) }
        for (index, account) in accounts.enumerated() {
            if Task.isCancelled { return .cancelled }
            await progress(index + 1, accounts.count, account)
            do {
                try await signIn(account)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return Task.isCancelled ? .cancelled : .failed(describe(error))
            }
        }
        if Task.isCancelled { return .cancelled }
        do {
            try await promote()
            return .promoted
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(describe(error))
        }
    }

    /// What this machine is after a promotion attempt. Only a promotion the web
    /// accepted makes it the server; a cancel or a failure leaves it exactly
    /// what it was — a follower stays a follower, an unelected Mac keeps
    /// polling — because the web was never told anything.
    static func stanceAfter(_ outcome: Outcome, before: RoleMemory.Stance?) -> RoleMemory.Stance? {
        if case .promoted = outcome { return .server }
        return before
    }

    /// "Signing into Personal (1 of 3)…"
    static func stepText(nickname: String, index: Int, count: Int) -> String {
        "Signing into \(nickname) (\(index) of \(count))…"
    }
}
