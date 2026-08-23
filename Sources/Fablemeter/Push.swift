import Foundation

// MARK: - Payload

/// What the web companion receives after each completed poll pass: the same
/// numbers the menu bar is drawing, and nothing else. No credential, no email,
/// no response body — the site is a remote copy of the gauge, so it gets the
/// gauge's inputs: label, nickname, the three buckets, and the headroom the
/// user's own Fable-first setting resolves to.
///
/// Built with `JSONSerialization` and explicit `NSNull` rather than `Codable`
/// so nullability is structural: a missing reading has no path to `0`, because
/// the only stand-in for it is null itself. The distinction the whole app turns
/// on has to survive the wire the same way it survives the screen.
enum PushPayload {
    static func body(
        accounts: [Account],
        states: [UUID: AccountState],
        fableFirst: Bool,
        now: Date = Date()
    ) -> [String: Any] {
        [
            "updatedAt": iso.string(from: now),
            "accounts": accounts.map { account -> [String: Any] in
                let state = states[account.id]
                let snapshot = state?.snapshot
                let headroom = snapshot?.headroom(fableFirst: fableFirst)
                return [
                    "id": account.id.uuidString,
                    "label": String(account.character),
                    "nickname": account.nickname,
                    "headroom": scalar(headroom),
                    "verdict": Verdict.word(headroom: headroom),
                    "isStale": state?.isStale ?? false,
                    "buckets": [
                        "fiveHour": bucket(snapshot?.fiveHour),
                        "weekly": bucket(snapshot?.weekly),
                        "fable": bucket(snapshot?.fable),
                    ],
                ]
            },
        ]
    }

    static func data(
        accounts: [Account],
        states: [UUID: AccountState],
        fableFirst: Bool,
        now: Date = Date()
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: body(
                accounts: accounts, states: states, fableFirst: fableFirst, now: now
            ),
            options: [.sortedKeys]
        )
    }

    /// A bucket the server never sent and a bucket it sent with a null reading
    /// both go out as null readings: the contract has no word for "absent", and
    /// null is the honest one of the two words it does have. Zero is never it.
    private static func bucket(_ bucket: UsageBucket?) -> [String: Any] {
        [
            "percent": scalar(bucket?.percent),
            "resetsAt": bucket?.resetsAt.map { iso.string(from: $0) as Any } ?? NSNull(),
        ]
    }

    private static func scalar(_ value: Double?) -> Any { value ?? NSNull() }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Pusher

/// Fire-and-forget. A push can fail forever without the gauge noticing: no
/// retry ladder of its own (the next poll pass is the retry), no state write,
/// no UI, one log line per outcome. The ten-second timeout is so a hung push
/// cannot stack up behind a healthy poll loop.
final class Pusher {
    private let secret: String?
    private let endpoint = URL(string: "https://fablemeter.oniconic.app/api/push")!

    /// The secret is read once, at startup, and its value goes into the
    /// Authorization header and nowhere else — never a log line, never an
    /// error message. A missing or unreadable file switches the pusher off for
    /// the whole session, said once so five-minute polling does not turn one
    /// absent file into a log column.
    init(secretFile: URL = Store.directory.appendingPathComponent("push-secret.txt")) {
        let raw = try? String(contentsOf: secretFile, encoding: .utf8)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        secret = (trimmed?.isEmpty == false) ? trimmed : nil
        if secret == nil {
            Log.push.notice("push: no secret, disabled")
        }
    }

    func push(accounts: [Account], states: [UUID: AccountState], fableFirst: Bool) {
        guard let secret else { return }
        let payload: Data
        do {
            payload = try PushPayload.data(
                accounts: accounts, states: states, fableFirst: fableFirst
            )
        } catch {
            Log.push.error("push failed encoding")
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        let count = accounts.count
        Task.detached {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    Log.push.notice("push ok accounts=\(count, privacy: .public)")
                } else {
                    Log.push.notice("push failed status=\(code, privacy: .public)")
                }
            } catch {
                // The same vetted vocabulary the gauge uses — never a body.
                let verdict = NetworkFailure.text(for: error) ?? NetworkFailure.genericText
                Log.push.notice("push failed verdict=\(verdict, privacy: .public)")
            }
        }
    }
}
