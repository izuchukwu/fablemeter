import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Roles

/// One machine per owner polls Anthropic and posts to Slack: the server. Every
/// other machine follows it through the web companion and never refreshes a
/// token of its own. That split is what keeps two machines from spending the
/// same rotating refresh token — the one way accounts have ever been bricked.
enum Role: String, Equatable {
    case server
    case follower
}

struct ServerInfo: Equatable {
    let machineId: String
    let machine: String
    let since: Date?
}

struct MachineInfo: Equatable {
    let machineId: String
    let machine: String
    let lastSeen: Date?
    let role: Role?
}

/// What `GET /api/state` answers. `snapshot` is the raw push payload the
/// server last sent — kept as JSON rather than decoded, so a follower hands on
/// exactly what the server measured, nulls included, and cannot turn one into
/// a zero on the way through.
struct RemoteState {
    let snapshot: [String: Any]?
    let server: ServerInfo?
    let you: Role?
    let machines: [MachineInfo]
    /// The web's own word that `snapshot` is not the named server's reading.
    /// Honoured when present, never required: see `snapshotIsServers`.
    var snapshotStale: Bool = false

    /// Pure, so the selftest can drive every shape the endpoint may return.
    static func decode(_ data: Data) -> RemoteState? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let server = (json["server"] as? [String: Any]).flatMap(serverInfo)
        let you = ((json["you"] as? [String: Any])?["role"] as? String).flatMap(Role.init(rawValue:))
        // With nobody elected the web reports every machine, the caller
        // included, as "server". That is "nobody chose", not "everybody is",
        // so roles are dropped rather than believed; `election` says which.
        let elected = server != nil
        let machines = ((json["machines"] as? [[String: Any]]) ?? []).compactMap { row -> MachineInfo? in
            guard let id = row["machineId"] as? String else { return nil }
            return MachineInfo(
                machineId: id,
                machine: (row["machine"] as? String) ?? id,
                lastSeen: ISODate.parse(row["lastSeen"] as? String),
                role: elected ? (row["role"] as? String).flatMap(Role.init(rawValue:)) : nil
            )
        }
        return RemoteState(
            snapshot: json["snapshot"] as? [String: Any],
            server: server, you: elected ? you : nil, machines: machines,
            snapshotStale: SnapshotSource.isTrue(json["snapshotStale"])
        )
    }

    static func serverInfo(_ row: [String: Any]) -> ServerInfo? {
        guard let id = row["machineId"] as? String else { return nil }
        return ServerInfo(
            machineId: id,
            machine: (row["machine"] as? String) ?? id,
            since: ISODate.parse(row["since"] as? String)
        )
    }
}

/// Whether the snapshot a follower was handed is the named server's own
/// reading.
///
/// It is not always. A push already in flight from the OLD server can land
/// after another machine is promoted, so for a while the web stores one
/// machine's numbers under another machine's name. Drawn as live, those
/// numbers would be the wrong machine's, and `fablemeter --guard` would judge
/// on them. So a follower believes a snapshot only when it says which machine
/// measured it and that machine is the server; anything else is shown as
/// stale, fails the guard closed, and fires no notifications, until the
/// server's own push arrives.
///
/// The web may also mark such a snapshot itself (`snapshotStale` on the
/// response, or `stale` on the snapshot). Either is honoured; neither is
/// needed, because the machine check stands on its own.
enum SnapshotSource {
    static func isServers(snapshot: [String: Any]?, server: ServerInfo?, webSaysStale: Bool) -> Bool {
        guard let snapshot else { return false }
        if webSaysStale || isTrue(snapshot["stale"]) { return false }
        // Nobody elected: every Mac measures for itself, and there is no one
        // for the snapshot to be wrongly attributed to.
        guard let server else { return true }
        return (snapshot["machineId"] as? String) == server.machineId
    }

    /// True only for a JSON `true`. A number is not a flag, even 1 — Darwin
    /// would otherwise bridge `NSNumber(1)` to `true` — and anything absent
    /// or malformed is false, which here means "no marker", never "trusted":
    /// trust comes only from the machine check.
    static func isTrue(_ any: Any?) -> Bool {
        guard let any else { return false }
        if type(of: any) == Bool.self, let flag = any as? Bool { return flag }
        if FollowedSnapshot.isBoolean(any) { return (any as? NSNumber)?.boolValue ?? false }
        return false
    }
}

extension RemoteState {
    /// See `SnapshotSource`: false for a snapshot a follower must not treat as
    /// the server's live reading.
    var snapshotIsServers: Bool {
        SnapshotSource.isServers(snapshot: snapshot, server: server, webSaysStale: snapshotStale)
    }

    /// The warnings a follower should surface from this answer. None from a
    /// snapshot that is not the server's — those belong to another machine's
    /// ledger, and nothing is marked seen, so nothing is lost when the real
    /// server's snapshot arrives.
    func followerWarnings(shown: Set<String>, now: Date) -> (show: [ServerWarning], markSeen: Set<String>) {
        guard snapshotIsServers, let snapshot else { return ([], []) }
        return WarningReplay.decide(ServerWarning.decode(snapshot["warnings"]), shown: shown, now: now)
    }
}

/// Who is the owner's server, from this machine's point of view. Unelected is
/// its own state, not "server": it is what an upgraded install sees before
/// anyone has promoted anything, and it means "carry on as before".
enum Election: Equatable {
    case unelected
    case thisMachine
    case other(ServerInfo)
}

extension RemoteState {
    func election(machineId: String) -> Election {
        guard let server else { return .unelected }
        switch you {
        case .server: return .thisMachine
        case .follower: return .other(server)
        case nil: return server.machineId == machineId ? .thisMachine : .other(server)
        }
    }
}

/// The only question the poll loop asks: may this machine talk to Anthropic
/// right now?
///
/// - Nobody is the server, or the web says this machine is: poll. No server
///   at all is today's world, one Mac and no election, and an upgrade must not
///   stop it polling.
/// - The web says "you are a follower": never poll.
/// - The web cannot be reached: keep doing whatever was last decided. A
///   follower that loses the web does not promote itself — self-promotion
///   happens only by a person signing in on this machine — and a server that
///   loses the web keeps measuring, which costs nothing and bricks nothing.
enum RoleDecision {
    /// Checked in this order on purpose. "No server set" wins over whatever
    /// the endpoint says about `you`: an upgraded Mac must keep polling until
    /// someone is actually promoted, whatever the web's default role is for a
    /// machine nobody has chosen.
    static func shouldPoll(remote: RemoteState?, machineId: String, lastDecision: Bool) -> Bool {
        guard let remote else { return lastDecision }
        switch remote.election(machineId: machineId) {
        case .unelected, .thisMachine: return true
        case .other: return false
        }
    }
}

// MARK: - Web client

enum WebError: Error, Equatable {
    /// 401: the machine key is revoked or unknown. Reconnect.
    case keyRejected
    /// 409 from push: some other machine is the server now.
    case notServer
    case status(Int)
    case malformed
}

/// `/api/state` and `/api/promote`, authenticated with this machine's key.
/// The key goes into the Authorization header and nowhere else.
struct WebClient {
    static let base = URL(string: "https://fablemeter.oniconic.app")!

    let key: String
    let machineId: String
    let machine: String

    /// The follower's poll, and the heartbeat that puts every machine in the
    /// menu bar's machine list.
    func state() async throws -> RemoteState {
        var comps = URLComponents(url: Self.base.appendingPathComponent("api/state"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "machineId", value: machineId),
            URLQueryItem(name: "machine", value: machine),
        ]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await HTTP.data(for: request)
        try Self.check(response)
        guard let state = RemoteState.decode(data) else { throw WebError.malformed }
        return state
    }

    /// Makes THIS machine the owner's server, at once. There is deliberately no
    /// way to name another machine: promotion is something a person does while
    /// signing in here.
    func promote() async throws -> ServerInfo? {
        var request = URLRequest(url: Self.base.appendingPathComponent("api/promote"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "machineId": machineId, "machine": machine,
        ])
        let (data, response) = try await HTTP.data(for: request)
        try Self.check(response)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["server"] as? [String: Any]).flatMap(RemoteState.serverInfo)
    }

    static func check(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return
        case 401: throw WebError.keyRejected
        case 409: throw WebError.notServer
        default: throw WebError.status(code)
        }
    }
}

// MARK: - Warnings across machines

/// A warning the server fired, as it travels in the push payload.
struct ServerWarning: Equatable {
    let key: String
    let title: String
    let body: String
    let firedAt: Date

    var json: [String: Any] {
        ["key": key, "title": title, "body": body, "firedAt": ISODate.string(firedAt)]
    }

    static func decode(_ rows: Any?) -> [ServerWarning] {
        ((rows as? [[String: Any]]) ?? []).compactMap { row in
            guard let key = row["key"] as? String,
                  let title = row["title"] as? String,
                  let firedAt = ISODate.parse(row["firedAt"] as? String)
            else { return nil }
            return ServerWarning(key: key, title: title, body: (row["body"] as? String) ?? "", firedAt: firedAt)
        }
    }
}

/// The server's memory of what it warned about in the last day, so it can tell
/// the followers. Pruned on every read; nothing older than the window travels.
final class WarningLedger: @unchecked Sendable {
    static let window: TimeInterval = 24 * 3600
    private let entries = Locked<[ServerWarning]>(initialState: [])

    func record(_ warnings: [UsageWarning], at now: Date = Date()) {
        guard !warnings.isEmpty else { return }
        entries.withLock { list in
            for warning in warnings where !list.contains(where: { $0.key == warning.key }) {
                list.append(ServerWarning(key: warning.key, title: warning.title, body: warning.body, firedAt: now))
            }
        }
    }

    func recent(now: Date = Date()) -> [ServerWarning] {
        entries.withLock { list in
            list.removeAll { now.timeIntervalSince($0.firedAt) > Self.window }
            return list
        }
    }
}

/// Which of the server's warnings a follower should put on its own screen.
///
/// Only ones it has not shown, and only ones fired in the last half hour: a
/// Mac that wakes after a night must not replay a crossing the server posted
/// to Slack hours ago. Everything older is marked seen without being shown,
/// so it never comes back either. Pure, so the selftest pins the window.
enum WarningReplay {
    static let window: TimeInterval = 30 * 60

    static func decide(
        _ warnings: [ServerWarning], shown: Set<String>, now: Date
    ) -> (show: [ServerWarning], markSeen: Set<String>) {
        var show: [ServerWarning] = []
        var seen = Set<String>()
        for warning in warnings where !shown.contains(warning.key) {
            seen.insert(warning.key)
            let age = now.timeIntervalSince(warning.firedAt)
            if age >= -120 && age <= window { show.append(warning) }
        }
        return (show, seen)
    }
}

// MARK: - Follower state

extension LocalState {
    /// A follower's local file is the SERVER's snapshot, handed on untouched —
    /// including `updatedAt`, because staleness has to mean "when the server
    /// last measured", not "when this machine last copied". Only the active
    /// marker is this machine's own.
    ///
    /// It is matched on the Anthropic account UUID, never on the label. Labels
    /// are picked per machine, so "C" here and "C" on the server can be two
    /// different accounts, and a single wrong match is a guard saying "clear"
    /// about the wrong account. So: exactly one row whose `accountId` equals
    /// the one this machine's Claude Code is signed into, or nothing is active
    /// and `activeResolved` is false — which the guard answers with "cannot
    /// tell", never with a guess.
    ///
    /// `fromServer` false (see `SnapshotSource`): the numbers are kept but
    /// every row is marked stale and the file says so, so the guard answers
    /// "cannot tell" instead of judging another machine's reading.
    static func body(
        followingServer snapshot: [String: Any], activeAccountId: String?, fromServer: Bool = true
    ) -> [String: Any] {
        var payload = snapshot
        payload.removeValue(forKey: "warnings")
        payload["sourceIsServer"] = fromServer
        let rows = (payload["accounts"] as? [[String: Any]]) ?? []
        let wanted = AccountIdentity.normalize(activeAccountId)
        let hits = wanted == nil ? 0 : rows.filter {
            AccountIdentity.normalize($0["accountId"] as? String) == wanted
        }.count
        let resolved = hits == 1
        payload["accounts"] = rows.map { row -> [String: Any] in
            var row = row
            row["isActive"] = resolved && AccountIdentity.normalize(row["accountId"] as? String) == wanted
            if !fromServer { row["isStale"] = true }
            return row
        }
        payload["activeResolved"] = resolved
        return payload
    }
}

extension ISODate {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
