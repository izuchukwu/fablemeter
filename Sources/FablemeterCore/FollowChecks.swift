import Foundation

extension CoreChecks {
    // MARK: Drawing the server's numbers

    static func followerDrawing(_ check: Check) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func stamp(_ offset: TimeInterval) -> String { ISODate.string(now.addingTimeInterval(offset)) }
        let personal = "5b2d6c1e-9f1a-4c3b-8e7d-2a1b3c4d5e6f"
        let payload: [String: Any] = [
            "updatedAt": stamp(-60),
            "machine": "fly-iconic",
            "accounts": [
                ["id": "A", "label": "P", "nickname": "Personal", "accountId": personal.uppercased(),
                 "headroom": 71, "verdict": "Available", "isStale": false,
                 "buckets": ["fiveHour": ["percent": 29, "resetsAt": stamp(3600)],
                             "weekly": ["percent": 10.5, "resetsAt": NSNull()],
                             "fable": ["percent": NSNull(), "resetsAt": NSNull()]]],
                ["id": "B", "label": "C", "nickname": "Charm",
                 "headroom": 0, "verdict": "Blocked", "isStale": true,
                 "buckets": ["fiveHour": ["percent": 0, "resetsAt": NSNull()],
                             "weekly": ["percent": 100, "resetsAt": NSNull()],
                             "fable": ["percent": 100, "resetsAt": NSNull()]]],
            ] as [[String: Any]],
        ]
        // Round-trip through real JSON, so the numbers arrive the way the web
        // hands them over, not as the Swift literals above.
        let wire = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let followed = FollowedSnapshot.decode(wire)
        let p = followed.accounts.first
        let c = followed.accounts.dropFirst().first

        check("follow: every server row becomes a row here, in order",
              followed.accounts.map(\.label) == ["P", "C"], "\(followed.accounts.map(\.label))")
        check("follow: the machine that measured is named", followed.machine == "fly-iconic", "")
        check("follow: a reported number is a reading", p?.snapshot.fiveHour?.percent == 29, "")
        check("follow: a fractional reading survives", p?.snapshot.weekly?.percent == 10.5, "")
        check("follow: a null reading stays null, never zero",
              p?.snapshot.fable != nil && p?.snapshot.fable?.percent == nil, "")
        check("follow: a reported zero stays zero", c?.snapshot.fiveHour?.percent == 0, "")
        check("follow: the account id is normalized (lowercase)", p?.accountId == personal, "")
        check("follow: headroom comes from the same policy as local polling",
              p?.snapshot.headroom(fableFirst: true) == 71, "\(String(describing: p?.snapshot.headroom(fableFirst: true)))")
        check("follow: Fable-first off ignores Fable here too",
              c?.snapshot.headroom(fableFirst: false) == 0 && c?.snapshot.isFableExhausted == true, "")
        if let p, let c {
            check("follow: a fresh, healthy server row draws live",
                  followed.state(for: p, now: now).error == nil, "")
            check("follow: a row the server itself could not refresh draws hollow",
                  followed.state(for: c, now: now).error == FollowedSnapshot.staleText, "")
            check("follow: a snapshot older than 12 minutes draws hollow",
                  followed.state(for: p, now: now.addingTimeInterval(13 * 60)).error == FollowedSnapshot.staleText, "")
            check("follow: stale still shows the server's numbers, not blanks",
                  followed.state(for: p, now: now.addingTimeInterval(13 * 60)).snapshot?.fiveHour?.percent == 29, "")
        }
        let undated = FollowedSnapshot.decode(["accounts": [] as [[String: Any]]])
        check("follow: a snapshot with no updatedAt counts as old, never fresh", undated.isOld(now: now), "")
        check("follow: numbers decode from Swift natives too (Linux shape)",
              FollowedSnapshot.number(Int(42)) == 42 && FollowedSnapshot.number(Double(1.5)) == 1.5
              && FollowedSnapshot.number(NSNull()) == nil && FollowedSnapshot.number(nil) == nil, "")
    }

    // MARK: The Server submenu

    static func serverMenu(_ check: Check) {
        let me = "MAC-1"
        func remote(server: String?, machines: [(String, String)]) -> RemoteState {
            var json: [String: Any] = [
                "machines": machines.map { ["machineId": $0.0, "machine": $0.1, "role": "server"] },
            ]
            if let server {
                json["server"] = ["machineId": server, "machine": machines.first { $0.0 == server }?.1 ?? server]
                json["you"] = ["role": server == me ? "server" : "follower"]
            }
            let data = try! JSONSerialization.data(withJSONObject: json)
            return RemoteState.decode(data)!
        }
        let fleet = [("MAC-1", "Izu's MacBook"), ("FLY-1", "fly-iconic")]

        let noKey = ServerMenuModel.items(hasKey: false, remote: nil, machineId: me, promotion: nil, busy: false)
        check("menu: without a web key it says so and offers Connect, nothing else",
              noKey == [.caption(ServerMenuModel.notConnectedText), .connect], "\(noKey)")

        let unreached = ServerMenuModel.items(hasKey: true, remote: nil, machineId: me, promotion: nil, busy: false)
        check("menu: web not reached yet still offers promotion",
              unreached == [.caption(ServerMenuModel.unreachedText), .divider, .makeThisMacServer(enabled: true)], "\(unreached)")

        let unelected = ServerMenuModel.items(hasKey: true, remote: remote(server: nil, machines: fleet), machineId: me, promotion: nil, busy: false)
        check("menu: unelected says so plainly, first",
              unelected.first == .caption(ServerMenuModel.unelectedText), "\(unelected)")
        check("menu: unelected checks no machine (nobody chose; the web's 'server' default is not believed)",
              !unelected.contains { if case .machine(_, true) = $0 { return true }; return false }, "\(unelected)")
        check("menu: unelected offers Make This Mac the Server",
              unelected.last == .makeThisMacServer(enabled: true), "")

        let follower = ServerMenuModel.items(hasKey: true, remote: remote(server: "FLY-1", machines: fleet), machineId: me, promotion: nil, busy: false)
        check("menu: following, the server is listed first with the checkmark",
              follower.first == .machine(title: "fly-iconic", isServer: true), "\(follower)")
        check("menu: following, this Mac is marked and not checked",
              follower.contains(.machine(title: "Izu's MacBook (This Mac)", isServer: false)), "")
        check("menu: following, the one action is promoting this Mac",
              follower.last == .makeThisMacServer(enabled: true)
              && follower.filter { if case .makeThisMacServer = $0 { return true }; return false }.count == 1, "")

        let server = ServerMenuModel.items(hasKey: true, remote: remote(server: "MAC-1", machines: fleet), machineId: me, promotion: nil, busy: false)
        check("menu: as the server, this Mac carries the checkmark",
              server.first == .machine(title: "Izu's MacBook (This Mac)", isServer: true), "\(server)")
        check("menu: as the server, there is nothing to click",
              !server.contains { if case .makeThisMacServer = $0 { return true }; return false }, "")

        let busy = ServerMenuModel.items(hasKey: true, remote: remote(server: "FLY-1", machines: fleet), machineId: me, promotion: nil, busy: true)
        check("menu: while another sign-in runs, promotion is disabled, not hidden",
              busy.last == .makeThisMacServer(enabled: false), "")

        let promoting = ServerMenuModel.items(hasKey: true, remote: remote(server: "FLY-1", machines: fleet), machineId: me,
                                              promotion: "Signing into Personal (1 of 3)…", busy: true)
        check("menu: mid-promotion it shows the step and a way out, nothing else",
              promoting == [.caption("Signing into Personal (1 of 3)…"), .divider, .cancelPromotion], "\(promoting)")

        let absent = ServerMenuModel.items(hasKey: true, remote: remote(server: "FLY-1", machines: [("MAC-1", "Izu's MacBook")]),
                                           machineId: me, promotion: nil, busy: false)
        check("menu: a server missing from the 24h list is still shown, checked",
              absent.first == .machine(title: "FLY-1", isServer: true), "\(absent)")
    }

    // MARK: Promoting this Mac

    static func promoteSequence(_ check: Check) {
        struct Boom: Error {}
        let accounts = [
            Account(email: "p@x.example", nickname: "Personal", label: "P", refreshToken: "-"),
            Account(email: "c@x.example", nickname: "Charm", label: "C", refreshToken: "-"),
            Account(email: "i@x.example", nickname: "Iconic", label: "I", refreshToken: "-"),
        ]
        final class Log: @unchecked Sendable {
            let entries = Locked<[String]>(initialState: [])
            func add(_ s: String) { entries.withLock { $0.append(s) } }
            var all: [String] { entries.withLock { $0 } }
        }
        func run(failAt: Int? = nil, cancelAt: Int? = nil, promoteFails: Bool = false) -> (PromoteSequence.Outcome, [String]) {
            let log = Log()
            let done = DispatchSemaphore(value: 0)
            let result = Locked<PromoteSequence.Outcome?>(initialState: nil)
            Task.detached {
                let outcome = await PromoteSequence.run(
                    accounts: accounts,
                    progress: { i, n, a in log.add("step \(i)/\(n) \(a.nickname)") },
                    signIn: { a in
                        log.add("sign \(a.label)")
                        if let failAt, a.label == accounts[failAt].label { throw Boom() }
                        if let cancelAt, a.label == accounts[cancelAt].label { throw CancellationError() }
                    },
                    promote: {
                        log.add("promote")
                        if promoteFails { throw Boom() }
                    },
                    describe: { _ in "boom" }
                )
                result.withLock { $0 = outcome }
                done.signal()
            }
            done.wait()
            return (result.withLock { $0 } ?? .failed("no result"), log.all)
        }

        let ok = run()
        check("promote: all three sign in, one at a time, in order, then the web is told",
              ok.0 == .promoted && ok.1 == ["step 1/3 Personal", "sign P", "step 2/3 Charm", "sign C", "step 3/3 Iconic", "sign I", "promote"], "\(ok.1)")
        let failed = run(failAt: 1)
        check("promote: a failed sign-in stops everything and never calls /api/promote",
              failed.0 == .failed("boom") && !failed.1.contains("promote") && !failed.1.contains("sign I"), "\(failed.1)")
        let cancelled = run(cancelAt: 0)
        check("promote: a cancelled sign-in is a cancel, and the web is never told",
              cancelled.0 == .cancelled && !cancelled.1.contains("promote"), "\(cancelled.1)")
        let refused = run(promoteFails: true)
        check("promote: the web refusing the promotion is a failure, not a success",
              refused.0 == .failed("boom"), "")
        check("promote: the step text reads the way the menu shows it",
              PromoteSequence.stepText(nickname: "Personal", index: 1, count: 3) == "Signing into Personal (1 of 3)…", "")
        check("promote: only an accepted promotion makes this machine the server",
              PromoteSequence.stanceAfter(.promoted, before: .follower) == .server, "")
        check("promote: a cancel leaves a follower a follower",
              PromoteSequence.stanceAfter(.cancelled, before: .follower) == .follower, "")
        check("promote: a failure leaves a follower a follower",
              PromoteSequence.stanceAfter(.failed("x"), before: .follower) == .follower, "")
        check("promote: a failure leaves an unelected Mac unelected (still polling)",
              PromoteSequence.stanceAfter(.failed("x"), before: .unelected) == .unelected
              && StartupRole.mayPoll(live: nil, remembered: PromoteSequence.stanceAfter(.failed("x"), before: .unelected)), "")
        check("promote: a failed promotion of a follower still may not poll",
              !StartupRole.mayPoll(live: nil, remembered: PromoteSequence.stanceAfter(.failed("x"), before: .follower)), "")
        let nothing = DispatchSemaphore(value: 0)
        let empty = Locked<PromoteSequence.Outcome?>(initialState: nil)
        Task.detached {
            let o = await PromoteSequence.run(accounts: [], progress: { _, _, _ in }, signIn: { _ in }, promote: {}, describe: { _ in "" })
            empty.withLock { $0 = o }
            nothing.signal()
        }
        nothing.wait()
        check("promote: with no accounts there is nothing to promote",
              empty.withLock { $0 } == .failed(PromoteSequence.noAccountsText), "")
    }
}
