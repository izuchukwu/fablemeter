import Foundation
import os

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
        now: Date = Date(),
        machine: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
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
        // Named machines let the key-management page say which Mac last
        // pushed, so a lost one is recognizable before it is cut off.
        // Optional, and omitted rather than nulled when unnamed: the contract
        // reserves null for a reading that exists and is empty.
        if let machine { payload["machine"] = machine }
        return payload
    }

    static func data(
        accounts: [Account],
        states: [UUID: AccountState],
        fableFirst: Bool,
        now: Date = Date(),
        machine: String? = nil
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: body(
                accounts: accounts, states: states, fableFirst: fableFirst,
                now: now, machine: machine
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
    private let keys: PushKeyStore
    private let endpoint = URL(string: "https://fablemeter.oniconic.app/api/push")!
    /// How the key-management page names this Mac.
    private let machine = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    /// Written by the detached completion, read by the next pass — locked, not
    /// hoped about.
    private struct Flags {
        var loggedMissing = false
        var rejected: String?
    }
    private let flags = OSAllocatedUnfairLock<Flags>(initialState: Flags())

    init(keys: PushKeyStore = .standard) {
        self.keys = keys
    }

    /// A key the server has rejected stays rejected — retrying it every five
    /// minutes is hammering a locked door with the same key. Only a
    /// *different* key (a reconnect, or a re-provisioned file) resumes. Pure,
    /// so the selftest can pin the policy.
    static func isSuppressed(key: String?, rejected: String?) -> Bool {
        key != nil && key == rejected
    }

    func push(accounts: [Account], states: [UUID: AccountState], fableFirst: Bool) {
        // Resolved per pass rather than once at startup, so a connect that
        // lands mid-session starts pushing on the next pass without a
        // relaunch. The value goes into the Authorization header and nowhere
        // else — never a log line, never an error message. No key at all is
        // said once, so five-minute polling does not turn one absent key into
        // a log column.
        guard let key = keys.currentKey() else {
            let firstTime = flags.withLock { state -> Bool in
                if state.loggedMissing { return false }
                state.loggedMissing = true
                return true
            }
            if firstTime { Log.push.notice("push: no key, disabled — connect from the ⋯ menu") }
            return
        }
        guard !flags.withLock({ Self.isSuppressed(key: key, rejected: $0.rejected) }) else {
            return
        }
        let payload: Data
        do {
            payload = try PushPayload.data(
                accounts: accounts, states: states, fableFirst: fableFirst, machine: machine
            )
        } catch {
            Log.push.error("push failed encoding")
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        let count = accounts.count
        Task.detached { [flags] in
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch code {
                case 200:
                    Log.push.notice("push ok accounts=\(count, privacy: .public)")
                case 401:
                    // The server no longer knows this key — revoked, or the
                    // account behind it deleted. Said once; the gauge is
                    // untouched and the next different key resumes.
                    flags.withLock { $0.rejected = key }
                    Log.push.notice("push: key rejected — reconnect from the ⋯ menu")
                default:
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
