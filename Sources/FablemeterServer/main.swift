@testable import FablemeterCore
import Foundation

// fablemeter-server — the headless Fablemeter.
//
//   run       the daemon: poll Anthropic as the owner's server, or follow the
//             server through the web companion; write ~/.claude/fablemeter/
//             state.json either way; post Slack only as the server.
//   connect   get this machine a key for the web companion (paste-back).
//   promote   sign into each account here, one at a time, then make this
//             machine the owner's server.
//   status    who is the server, which machines are around, what is signed in.
//   selftest  the core's pure checks, runnable on the box itself.
//   oob-test  prove the paste-back sign-in without keeping anything.

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fablemeter-server: \(message)\n".utf8))
    exit(1)
}

func ask(_ prompt: String) -> String {
    print(prompt, terminator: "")
    fflush(stdout)
    // No timeout: a sign-in code lives five minutes and a person carries it by
    // hand. EOF means nobody is there, which ends the command.
    guard let line = readLine(strippingNewline: true) else { fail("no input (stdin closed)") }
    return line.trimmingCharacters(in: .whitespacesAndNewlines)
}

func blocking(_ body: @escaping () async -> Int32) -> Never {
    let semaphore = DispatchSemaphore(value: 0)
    var status: Int32 = 1
    Task {
        status = await body()
        semaphore.signal()
    }
    semaphore.wait()
    exit(status)
}

/// Where the credentials live. On Linux, `Store.directory` already honours
/// FABLEMETER_DATA_DIR. On macOS the default is the MENU BAR APP's own store,
/// and a second process spending those rotating tokens is the one thing that
/// has ever bricked every account at once — so here it must be named, and it
/// must not be the app's.
func claimDataDirectory() {
    #if os(macOS)
    guard let explicit = ProcessInfo.processInfo.environment["FABLEMETER_DATA_DIR"], !explicit.isEmpty else {
        fail("on macOS, set FABLEMETER_DATA_DIR to a directory of its own. The default is the menu bar app's account store, and two processes spending the same refresh tokens destroys them.")
    }
    let chosen = URL(fileURLWithPath: explicit, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let app = Store.directory.standardizedFileURL.resolvingSymlinksInPath()
    guard chosen.path != app.path else {
        fail("FABLEMETER_DATA_DIR points at the menu bar app's account store. Refusing.")
    }
    Store.directoryOverride = chosen
    #endif
}

func webClient() -> WebClient? {
    guard let key = PushKeyStore.standard.currentKey() else { return nil }
    return WebClient(key: key, machineId: MachineIdentity.id(), machine: MachineIdentity.displayName)
}

/// One paste-back sign-in. Returns the credentials; persisting is the
/// caller's job, done the moment this returns.
func signIn(heading: String) async -> (email: String, refreshToken: String)? {
    while true {
        let attempt = OOB.begin()
        print("\n\(heading)")
        print("Open this on any device, sign in to the account, approve:\n")
        print("  \(attempt.url.absoluteString)\n")
        let pasted = ask("Paste the code here (or 'skip'): ")
        if pasted.lowercased() == "skip" { return nil }
        do {
            return try await OOB.complete(attempt, pasted: pasted)
        } catch let error as OAuthError {
            print("  ✗ \(error.displayText) — let's try that one again.")
        } catch {
            print("  ✗ \(NetworkFailure.text(for: error) ?? NetworkFailure.genericText) — let's try that one again.")
        }
    }
}

switch command {
case "run":
    claimDataDirectory()
    let engine = Engine()
    blocking {
        await engine.run()
        return 0
    }

case "connect":
    claimDataDirectory()
    blocking {
        let state: String
        do { state = try WebConnect.randomHex(bytes: 16) } catch { fail("secure randomness unavailable") }
        print("Connect this machine (\(MachineIdentity.displayName)) to the Fablemeter web companion.")
        print("Open this on any device, sign in, confirm, and paste the code it shows:\n")
        print("  \(WebConnect.oobURL(state: state).absoluteString)\n")
        let pasted = ask("Code: ")
        let code: String
        do { code = try OOB.parse(pasted, expectedState: state) } catch { fail("that is not a code for this attempt") }
        do {
            let key = try await WebConnect.exchangeCode(code)
            guard PushKeyStore.standard.writeKeychain(key) else { fail("could not store the key") }
            print("✓ Connected. Machine id \(MachineIdentity.id()).")
            print("  Next: `fablemeter-server promote` to make this machine the server.")
            return 0
        } catch let error as ConnectError {
            fail(error.displayText)
        } catch {
            fail(NetworkFailure.text(for: error) ?? NetworkFailure.genericText)
        }
    }

case "promote":
    claimDataDirectory()
    blocking {
        guard let client = webClient() else { fail("not connected — run `fablemeter-server connect` first") }
        print("Promote \(MachineIdentity.displayName) to server.")
        print("Every account gets a fresh sign-in on THIS machine, one at a time, so no token is ever copied from another machine.")

        // Re-sign every account already here, then offer to add more.
        let existing = Store.load()
        for (index, account) in existing.enumerated() {
            let heading = "Account \(index + 1) of \(existing.count) — \(account.nickname) (\(account.email))"
            guard let result = await signIn(heading: heading) else {
                print("  skipped \(account.nickname); it keeps its current sign-in")
                continue
            }
            if ActiveAccount.normalize(result.email) != ActiveAccount.normalize(account.email) {
                let answer = ask("  That signed in as \(result.email), not \(account.email). Replace anyway? [y/N] ")
                guard answer.lowercased().hasPrefix("y") else { print("  kept the old sign-in"); continue }
            }
            do {
                // Persisted the moment it exists. Unconditional: a person just
                // signed in, and that fresh token is the one that must win.
                try Store.mutate { accounts in
                    guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
                    accounts[i].refreshToken = result.refreshToken
                    accounts[i].email = result.email
                }
                print("  ✓ \(account.nickname) signed in")
            } catch {
                fail("could not save \(account.nickname)'s sign-in — nothing was promoted")
            }
        }
        while true {
            let prompt = Store.load().isEmpty ? "Add an account now? [Y/n] " : "Add another account? [y/N] "
            let answer = ask(prompt).lowercased()
            let wantsMore = Store.load().isEmpty ? !answer.hasPrefix("n") : answer.hasPrefix("y")
            guard wantsMore else { break }
            let n = Store.load().count + 1
            guard let result = await signIn(heading: "Account \(n)") else { continue }
            let nickname = ask("  Nickname [\(Account.localPart(of: result.email))]: ")
            let label = ask("  One-character label for the gauge [auto]: ")
            let account = Account(
                email: result.email,
                nickname: nickname.isEmpty ? nil : nickname,
                label: label.isEmpty ? nil : label,
                refreshToken: result.refreshToken
            )
            do {
                try Store.mutate { $0.append(account) }
                print("  ✓ \(account.nickname) (\(account.label)) added")
            } catch {
                fail("could not save \(result.email) — nothing was promoted")
            }
        }
        guard !Store.load().isEmpty else { fail("no accounts signed in — nothing to promote") }
        do {
            let server = try await client.promote()
            print("\n✓ \(server?.machine ?? MachineIdentity.displayName) is now the server.")
            print("  Other machines stop polling on their next check. Start or restart `fablemeter-server run`.")
            return 0
        } catch WebError.keyRejected {
            fail("the web rejected this machine's key — run `fablemeter-server connect` again")
        } catch {
            fail("promotion failed: \(error)")
        }
    }

case "status":
    claimDataDirectory()
    blocking {
        let accounts = Store.load()
        print("machine   \(MachineIdentity.displayName)  (\(MachineIdentity.id()))")
        print("data dir  \(Store.directory.path)")
        print("accounts  \(accounts.isEmpty ? "none signed in here" : accounts.map { "\($0.label) \($0.nickname)" }.joined(separator: ", "))")
        print("slack     \(Slack.config() == nil ? "not configured" : "configured")")
        guard let client = webClient() else {
            print("web       not connected — run `fablemeter-server connect`")
            return 0
        }
        do {
            let remote = try await client.state()
            switch remote.election(machineId: client.machineId) {
            case .unelected: print("role      nobody is the server yet (every machine polls, as before)")
            case .thisMachine: print("role      SERVER (this machine)")
            case .other(let s): print("role      follower of \(s.machine)")
            }
            for m in remote.machines {
                let when = m.lastSeen.map { Format.relative($0) } ?? "never"
                let tag = m.machineId == client.machineId ? "  ← this machine" : ""
                print("          \(m.machine)  \(m.role?.rawValue ?? "-")  seen \(when)\(tag)")
            }
            return 0
        } catch {
            print("web       unreachable or refused: \(error)")
            return 1
        }
    }

case "selftest":
    blocking {
        var failures = 0
        CoreChecks.run { name, ok, detail in
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  \(detail)")")
            if !ok { failures += 1 }
        }
        print(failures == 0 ? "\nselftest: all checks passed" : "\nselftest: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }

case "oob-test":
    blocking { await OOBTest.run() }

default:
    print("""
    usage: fablemeter-server <command>

      connect    link this machine to the web companion (paste a code)
      promote    sign in each account here, one at a time, and become the server
      run        the daemon (server or follower, decided by the web)
      status     role, machines, accounts
      selftest   core checks
      oob-test   prove the paste-back sign-in, keeping nothing

    environment:
      FABLEMETER_DATA_DIR         where accounts and the machine key live (a Fly volume)
      FABLEMETER_SLACK_TOKEN      Slack bot token (with FABLEMETER_SLACK_CHANNEL)
      FABLEMETER_SLACK_CHANNEL    e.g. C0BT334MZMX
      FABLEMETER_SLACK_CONFIG     or: path to a {"token","channel"} JSON file
      FABLEMETER_FABLE_FIRST      0 to measure min(5-hour, weekly) only
      FABLEMETER_WARN_75/90/95, FABLEMETER_WARN_FAST_BURN   0 to silence
    """)
    exit(command == "help" || command == "--help" || command == "-h" ? 0 : 1)
}
