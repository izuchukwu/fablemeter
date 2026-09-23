import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The core's own pure checks, run by the menu bar app's `--selftest` and by
/// `fablemeter-server selftest` alike, so the server's logic is proven on the
/// machine it runs on and not only on the Mac that built it. No network, no
/// Keychain, no clock but the one passed in.
enum CoreChecks {
    typealias Check = (_ name: String, _ ok: Bool, _ detail: String) -> Void

    static func run(_ check: Check) {
        oob(check)
        roles(check)
        replay(check)
        followerState(check)
        wire(check)
        slackConfig(check)
    }

    // MARK: Paste-back sign-in

    static func oob(_ check: Check) {
        let state = "STATE123"
        func parse(_ s: String) -> Result<String, Error> { Result { try OOB.parse(s, expectedState: state) } }

        check("oob: code#state with the right state parses to the code",
              (try? parse("abc123#STATE123").get()) == "abc123", "")
        check("oob: a bare code parses (state absent is accepted — the verifier still guards it)",
              (try? parse("abc123").get()) == "abc123", "")
        check("oob: surrounding whitespace and a trailing newline are ignored",
              (try? parse("  abc123#STATE123 \n").get()) == "abc123", "")
        check("oob: a pasted callback URL yields its code",
              (try? parse("https://platform.claude.com/oauth/code/callback?code=abc123&state=STATE123").get()) == "abc123", "")
        if case .failure(let e) = parse("abc123#OTHER") {
            check("oob: a code for another attempt is refused", (e as? OOB.PasteError) == .stateMismatch, "")
        } else { check("oob: a code for another attempt is refused", false, "parsed") }
        if case .failure(let e) = parse("   ") {
            check("oob: an empty paste is refused", (e as? OOB.PasteError) == .empty, "")
        } else { check("oob: an empty paste is refused", false, "parsed") }
        if case .failure(let e) = parse("#STATE123") {
            check("oob: a state with no code is refused", (e as? OOB.PasteError) == .empty, "")
        } else { check("oob: a state with no code is refused", false, "parsed") }
        if case .failure(let e) = parse("https://platform.claude.com/oauth/code/callback?error=access_denied&error_description=nope") {
            check("oob: a denial URL surfaces as denied, not as a code", (e as? OOB.PasteError) == .denied("nope"), "")
        } else { check("oob: a denial URL surfaces as denied, not as a code", false, "parsed") }

        let url = OOB.authorizeURL(challenge: "CH", state: "ST")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        check("oob: redirect is Claude Code's MANUAL_REDIRECT_URL",
              items["redirect_uri"] == "https://platform.claude.com/oauth/code/callback", items["redirect_uri"] ?? "nil")
        check("oob: same authorize host as the browser flow",
              url.absoluteString.hasPrefix(Constants.authorizeURL + "?"), url.host ?? "nil")
        check("oob: PKCE S256 with our challenge and state",
              items["code_challenge"] == "CH" && items["code_challenge_method"] == "S256" && items["state"] == "ST", "")
        check("oob: client id, code=true, response_type=code, read-only scope",
              items["client_id"] == Constants.clientID && items["code"] == "true"
              && items["response_type"] == "code" && items["scope"] == Constants.scope, "")
        let a = OOB.begin(), b = OOB.begin()
        check("oob: every attempt has its own verifier and state", a.verifier != b.verifier && a.state != b.state, "")
        check("oob: the URL carries the challenge, never the verifier",
              !a.url.absoluteString.contains(a.verifier) && a.url.absoluteString.contains(PKCE.challenge(for: a.verifier)), "")
    }

    // MARK: Roles

    static func roles(_ check: Check) {
        let me = "ME", other = "OTHER"
        func remote(_ json: [String: Any]) -> RemoteState? {
            RemoteState.decode(try! JSONSerialization.data(withJSONObject: json))
        }
        let unelected = remote([
            "snapshot": NSNull(), "server": NSNull(), "you": ["role": "server"],
            "machines": [["machineId": me, "machine": "mac", "role": "server"],
                         ["machineId": other, "machine": "fly", "role": "server"]],
        ])!
        check("role: unelected is its own state, not 'server'", unelected.election(machineId: me) == .unelected, "")
        check("role: unelected drops the web's everyone-is-server roles", unelected.machines.allSatisfy { $0.role == nil } && unelected.you == nil, "")
        check("role: unelected keeps polling (upgrade changes nothing)",
              RoleDecision.shouldPoll(remote: unelected, machineId: me, lastDecision: false), "")

        let meServer = remote(["server": ["machineId": me, "machine": "mac"], "you": ["role": "server"], "machines": []])!
        let otherServer = remote(["server": ["machineId": other, "machine": "fly"], "you": ["role": "follower"], "machines": []])!
        let otherNoYou = remote(["server": ["machineId": other, "machine": "fly"], "machines": []])!
        let meNoYou = remote(["server": ["machineId": me, "machine": "mac"], "machines": []])!
        check("role: the web naming this machine means poll", RoleDecision.shouldPoll(remote: meServer, machineId: me, lastDecision: false), "")
        check("role: another server means never poll", !RoleDecision.shouldPoll(remote: otherServer, machineId: me, lastDecision: true), "")
        check("role: without 'you', the server id decides (other)", !RoleDecision.shouldPoll(remote: otherNoYou, machineId: me, lastDecision: true), "")
        check("role: without 'you', the server id decides (this)", RoleDecision.shouldPoll(remote: meNoYou, machineId: me, lastDecision: false), "")
        check("role: an unreachable web keeps a server polling", RoleDecision.shouldPoll(remote: nil, machineId: me, lastDecision: true), "")
        check("role: an unreachable web never promotes a follower", !RoleDecision.shouldPoll(remote: nil, machineId: me, lastDecision: false), "")

        check("role: a 409 demotes at once, even with the web unreachable",
              !Engine.nextIsServer(current: true, demoted: true, remote: nil, machineId: me), "")
        check("role: after a 409, another server keeps it a follower",
              !Engine.nextIsServer(current: true, demoted: true, remote: otherServer, machineId: me), "")
        check("role: only the web naming this machine again re-promotes it",
              Engine.nextIsServer(current: false, demoted: false, remote: meServer, machineId: me), "")

        func status(_ code: Int) -> WebError? {
            let r = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: code, httpVersion: nil, headerFields: nil)!
            do { try WebClient.check(r); return nil } catch { return error as? WebError }
        }
        check("role: 409 from the web reads as not-server", status(409) == .notServer, "")
        check("role: 401 reads as key rejected", status(401) == .keyRejected, "")
        check("role: 200 is fine", status(200) == nil, "")
        check("role: garbage from /api/state is refused, not guessed", RemoteState.decode(Data("nope".utf8)) == nil, "")
    }

    // MARK: Warning replay

    static func replay(_ check: Check) {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fresh = ServerWarning(key: "k1", title: "P: 5-hour at 92%", body: "Resets", firedAt: now.addingTimeInterval(-10 * 60))
        let old = ServerWarning(key: "k2", title: "C: weekly at 95%", body: "Resets", firedAt: now.addingTimeInterval(-3 * 3600))
        let edge = ServerWarning(key: "k3", title: "I: fast burn", body: "x", firedAt: now.addingTimeInterval(-30 * 60))
        let future = ServerWarning(key: "k4", title: "skew", body: "x", firedAt: now.addingTimeInterval(3600))
        let first = WarningReplay.decide([fresh, old, edge, future], shown: [], now: now)
        check("replay: a warning fired 10 minutes ago is shown", first.show.contains(fresh), "")
        check("replay: exactly 30 minutes old is still shown", first.show.contains(edge), "")
        check("replay: a 3-hour-old crossing is NOT replayed on wake", !first.show.contains(old), "")
        check("replay: a far-future stamp (clock skew) is not shown", !first.show.contains(future), "")
        check("replay: skipped ones are marked seen so they never come back", first.markSeen.isSuperset(of: ["k1", "k2", "k3", "k4"]), "")
        let second = WarningReplay.decide([fresh, old, edge], shown: first.markSeen, now: now)
        check("replay: each key is shown once", second.show.isEmpty, "\(second.show.count) re-shown")

        let ledger = WarningLedger()
        let w = UsageWarning(title: "t", body: "b", key: "dup")
        ledger.record([w], at: now)
        ledger.record([w], at: now.addingTimeInterval(60))
        check("ledger: a key is recorded once, with its first firing time",
              ledger.recent(now: now).count == 1 && ledger.recent(now: now).first?.firedAt == now, "")
        check("ledger: nothing older than a day travels", ledger.recent(now: now.addingTimeInterval(25 * 3600)).isEmpty, "")
        let round = ServerWarning.decode([fresh.json])
        check("ledger: warnings round-trip through the wire", round == [fresh], "\(round)")
    }

    // MARK: Follower state

    static func followerState(_ check: Check) {
        let serverStamp = "2026-09-23T10:00:00Z"
        let snapshot: [String: Any] = [
            "updatedAt": serverStamp,
            "machineId": "FLY",
            "warnings": [["key": "k", "title": "t", "body": "b", "firedAt": serverStamp]],
            "accounts": [
                ["id": "1", "label": "P", "nickname": "Personal", "headroom": 94.0, "verdict": "Available", "isStale": false,
                 "buckets": ["fiveHour": ["percent": 6.0, "resetsAt": NSNull()], "weekly": ["percent": NSNull(), "resetsAt": NSNull()], "fable": ["percent": 0.0, "resetsAt": NSNull()]]],
                ["id": "2", "label": "C", "nickname": "Charm", "headroom": NSNull(), "verdict": "No data", "isStale": true, "buckets": [:]],
            ],
        ]
        let body = LocalState.body(followingServer: snapshot, activeLabel: "P")
        check("follower: updatedAt is the SERVER's, not the copy time", (body["updatedAt"] as? String) == serverStamp, "")
        check("follower: the warnings list stays off the fleet's file", body["warnings"] == nil, "")
        let rows = (body["accounts"] as? [[String: Any]]) ?? []
        check("follower: the active account is marked by label", (rows.first?["isActive"] as? Bool) == true && (rows.last?["isActive"] as? Bool) == false, "")
        check("follower: active resolved when a label matched", (body["activeResolved"] as? Bool) == true, "")
        let buckets = rows.first?["buckets"] as? [String: Any]
        check("follower: a null reading stays null", ((buckets?["weekly"] as? [String: Any])?["percent"]) is NSNull, "")
        check("follower: a reported zero stays zero", ((buckets?["fable"] as? [String: Any])?["percent"] as? Double) == 0, "")
        check("follower: null headroom stays null", rows.last?["headroom"] is NSNull, "")
        let none = LocalState.body(followingServer: snapshot, activeLabel: nil)
        check("follower: no signed-in label means unresolved, never a guess", (none["activeResolved"] as? Bool) == false, "")
        let stranger = LocalState.body(followingServer: snapshot, activeLabel: "Z")
        check("follower: a label the server does not have is unresolved", (stranger["activeResolved"] as? Bool) == false, "")
        let encoded = (try? JSONSerialization.data(withJSONObject: body)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("follower: no token or email reaches the file", !encoded.lowercased().contains("token") && !encoded.contains("@"), "")
    }

    // MARK: Wire

    static func wire(_ check: Check) {
        let plain = PushPayload.body(accounts: [], states: [:], fableFirst: true)
        check("wire: without a machine id the payload is unchanged (old shape)", plain["machineId"] == nil && plain["warnings"] == nil, "")
        let w = ServerWarning(key: "k", title: "t", body: "b", firedAt: Date(timeIntervalSince1970: 0))
        let full = PushPayload.body(accounts: [], states: [:], fableFirst: true, machine: "fly", machineId: "ID", warnings: [w])
        check("wire: machineId travels", (full["machineId"] as? String) == "ID", "")
        check("wire: warnings travel with key, title, body, firedAt",
              ((full["warnings"] as? [[String: Any]])?.first?["firedAt"] as? String) == "1970-01-01T00:00:00Z", "")
        let url = WebConnect.oobURL(state: "abc")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        check("wire: the paste-back connect URL asks for mode=oob with our state",
              url.path == "/connect" && q.contains(URLQueryItem(name: "mode", value: "oob")) && q.contains(URLQueryItem(name: "state", value: "abc")), url.absoluteString)
    }

    // MARK: Slack config

    static func slackConfig(_ check: Check) {
        let env = ["FABLEMETER_SLACK_TOKEN": "xoxb-test", "FABLEMETER_SLACK_CHANNEL": "C1"]
        check("slack: token + channel from the environment", Slack.config(environment: env) == SlackConfig(token: "xoxb-test", channel: "C1"), "")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fm-slack-\(UUID().uuidString).json")
        try? Data(#"{"token":"xoxb-file","channel":"C2"}"#.utf8).write(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        check("slack: a config file named by the environment",
              Slack.config(environment: ["FABLEMETER_SLACK_CONFIG": dir.path]) == SlackConfig(token: "xoxb-file", channel: "C2"), "")
        check("slack: half an environment pair is not a config",
              Slack.config(environment: ["FABLEMETER_SLACK_TOKEN": "x", "FABLEMETER_SLACK_CONFIG": "/nonexistent/x.json"]) == nil, "")
    }
}
