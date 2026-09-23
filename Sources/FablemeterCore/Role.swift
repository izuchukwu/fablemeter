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
            server: server, you: elected ? you : nil, machines: machines
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
    /// marker is this machine's own: it is resolved here, by label, against
    /// whichever account this machine's Claude Code is signed into.
    static func body(followingServer snapshot: [String: Any], activeLabel: String?) -> [String: Any] {
        var payload = snapshot
        payload.removeValue(forKey: "warnings")
        let rows = (payload["accounts"] as? [[String: Any]]) ?? []
        var matched = false
        payload["accounts"] = rows.map { row -> [String: Any] in
            var row = row
            let hit = activeLabel != nil && (row["label"] as? String) == activeLabel
            if hit { matched = true }
            row["isActive"] = hit
            return row
        }
        payload["activeResolved"] = matched
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
