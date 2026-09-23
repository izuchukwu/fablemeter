import Foundation

// MARK: - Which account is being spent

/// Claude Code sessions switch accounts with `/login`, so "the active account"
/// is a fact about the machine that changes under us. It lives in
/// `~/.claude.json` under `oauthAccount.emailAddress`, which is the only field
/// read here: the credential itself sits in the keychain and is none of this
/// file's business.
///
/// **The honest limit, and every reader of the state file inherits it:** that
/// file is shared by every Claude Code session on the Mac and a `/login`
/// rewrites it in place. So it names the account of the most recent login, not
/// of the shell asking the question. Two sessions signed into different
/// accounts are indistinguishable here. Nothing in the environment carries a
/// per-session identity, so a caller that needs certainty passes `--account`
/// and a caller that does not gets the machine's best answer, clearly labelled.
enum ActiveAccount {
    static var claudeConfig: URL {
        Home.directory
            .appendingPathComponent(".claude.json")
    }

    /// Read-only, one field, and every failure is the same `nil`: an absent
    /// file, an unreadable one and a logged-out machine are all "cannot say",
    /// which is the answer that makes the guard refuse rather than guess.
    static func signedInEmail(at url: URL? = nil) -> String? {
        guard let data = try? Data(contentsOf: url ?? claudeConfig),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["oauthAccount"] as? [String: Any],
              let email = oauth["emailAddress"] as? String,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return email
    }

    static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Pure, so `--selftest` can drive every case without a home directory.
    ///
    /// Two accounts on one address returns `nil` rather than the first: an
    /// ambiguous answer to "which account is this shell spending" is not an
    /// answer, and the guard's job is to refuse exactly there.
    static func match(email: String?, accounts: [Account]) -> UUID? {
        guard let email else { return nil }
        let needle = normalize(email)
        guard !needle.isEmpty else { return nil }
        let hits = accounts.filter { normalize($0.email) == needle }
        return hits.count == 1 ? hits[0].id : nil
    }
}

// MARK: - The local read rail

/// The snapshot other agents on this Mac read to answer "may I start this
/// job?". The same numbers the gauge is drawing, written to a plain file after
/// every completed poll pass.
///
/// **It lives in its own directory on purpose.** The app's Application Support
/// directory holds `accounts.json` — live, single-use refresh tokens that
/// rotate on every refresh — and the whole fleet pointing file tooling at that
/// directory is a hazard worth designing out rather than documenting. Nothing
/// anyone reads here sits beside a credential.
///
/// The body is `PushPayload`'s, not a second encoder: the web companion and the
/// local file are the same gauge state going to two places, and a second
/// encoder is a second chance to collapse null into zero.
enum LocalState {
    static var directory: URL {
        Home.directory
            .appendingPathComponent(".claude/fablemeter", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("state.json") }

    /// Pure. `activeID` is resolved by the caller, which is the only place the
    /// email exists — it is matched against and then dropped, never written.
    /// The payload carries labels, nicknames and numbers; an address is
    /// identity, and identity is not what a usage gauge owes its readers.
    static func body(
        accounts: [Account],
        states: [UUID: AccountState],
        fableFirst: Bool,
        activeID: UUID?,
        now: Date = Date()
    ) -> [String: Any] {
        var payload = PushPayload.body(
            accounts: accounts, states: states, fableFirst: fableFirst, now: now
        )
        let rows = (payload["accounts"] as? [[String: Any]]) ?? []
        payload["accounts"] = rows.map { row -> [String: Any] in
            var row = row
            row["isActive"] = activeID != nil && (row["id"] as? String) == activeID?.uuidString
            return row
        }
        // Stated rather than inferred from the absence of an active row: a
        // reader must be able to tell "nobody is logged in" from "the logged-in
        // account is not one of these", and both from a stale file.
        payload["activeResolved"] = activeID != nil
        return payload
    }

    static func data(
        accounts: [Account],
        states: [UUID: AccountState],
        fableFirst: Bool,
        activeID: UUID?,
        now: Date = Date()
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: body(
                accounts: accounts, states: states, fableFirst: fableFirst,
                activeID: activeID, now: now
            ),
            options: [.sortedKeys, .prettyPrinted]
        )
    }
}

/// Writes the snapshot at the edge. Same discipline as `Pusher`: nothing past
/// this line may touch the gauge, the schedule or the screen, and a failure
/// says its piece once rather than turning a five-minute loop into a log
/// column.
@MainActor
final class LocalStateWriter {
    private var loggedFailure = false

    func write(accounts: [Account], states: [UUID: AccountState], fableFirst: Bool) {
        let activeID = ActiveAccount.match(
            email: ActiveAccount.signedInEmail(), accounts: accounts
        )
        do {
            let payload = try LocalState.data(
                accounts: accounts, states: states, fableFirst: fableFirst, activeID: activeID
            )
            try FileManager.default.createDirectory(
                at: LocalState.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            // Temp-plus-rename inside the same directory: a reader polling this
            // file must never catch it half-written, and the fleet's own bus
            // spent a night learning that lesson the other way round.
            try AtomicFile.write(payload, to: LocalState.file, mode: 0o644)
        } catch {
            if !loggedFailure {
                loggedFailure = true
                Log.store.notice("local state: write failed, disabled for this run")
            }
        }
    }
}
