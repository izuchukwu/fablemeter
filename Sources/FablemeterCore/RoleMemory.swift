import Foundation

// MARK: - What this machine last knew about its role

/// The role, remembered across restarts.
///
/// A follower that forgot it was one polled Anthropic on every launch — every
/// Mac boot once anyone was promoted, and any headless restart while the web
/// was unreachable — until a 409 or the web corrected it. Spending its own
/// token lineage bricks nothing, but "a follower never polls" is the promise,
/// and a promise that holds only while the process stays up is not one.
///
/// Also carries the server warnings already shown here, so a restarted
/// follower does not show a recent one a second time.
struct RoleMemory: Codable, Equatable {
    enum Stance: String, Codable {
        /// Nobody is anyone's server: today's world, keep polling.
        case unelected
        /// This machine is the owner's server.
        case server
        /// Another machine is. Never poll, never refresh a token.
        case follower
    }

    var stance: Stance
    var updatedAt: Date
    var shownWarnings: [String]

    static let shownCap = 500

    static var file: URL { MachineIdentity.directory.appendingPathComponent("role.json") }

    static func load(from url: URL? = nil) -> RoleMemory? {
        guard let data = try? Data(contentsOf: url ?? file) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(RoleMemory.self, from: data)
    }

    /// Best effort by design: failing to remember a role must never stop a
    /// machine working. The cost of a lost write is one poll pass after the
    /// next restart, which is exactly the bug this file shrinks, not a new one.
    func save(to url: URL? = nil) {
        let target = url ?? Self.file
        var copy = self
        if copy.shownWarnings.count > Self.shownCap {
            copy.shownWarnings = Array(copy.shownWarnings.suffix(Self.shownCap))
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? enc.encode(copy) else { return }
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try? AtomicFile.write(data, to: target, mode: 0o644)
    }

    static func stance(for election: Election) -> Stance {
        switch election {
        case .unelected: return .unelected
        case .thisMachine: return .server
        case .other: return .follower
        }
    }
}

/// May this machine talk to Anthropic right now? The one decision every start
/// and every tick makes, pure so the selftest pins the whole table.
///
///   live answer from the web  → it wins: unelected or this machine polls,
///                               another machine does not
///   no live answer            → the remembered stance: a follower stays a
///                               follower; server or unelected keeps polling
///   nothing live, nothing
///   remembered                → poll, as every install did before roles
///                               existed (an upgrade must not stop a Mac)
enum StartupRole {
    static func mayPoll(live: Election?, remembered: RoleMemory.Stance?) -> Bool {
        if let live {
            switch live {
            case .unelected, .thisMachine: return true
            case .other: return false
            }
        }
        return remembered != .follower
    }
}

// MARK: - Which Anthropic account a row is

/// The Anthropic account's own UUID for each of this machine's accounts.
///
/// Labels are chosen per machine and prove nothing across machines: a follower
/// that matched "which account am I signed into" by label judged whichever
/// server row shared the letter. The account UUID is the same fact on every
/// machine — the token response, the profile endpoint and Claude Code's own
/// `~/.claude.json` all carry it — so a follower matches on that or refuses.
///
/// Kept in its own file beside the machine id, keyed by this machine's local
/// account id, and deliberately NOT a field in the account store: nothing about
/// this feature ever writes the file that holds the refresh tokens.
enum AccountIdentity {
    static var file: URL { MachineIdentity.directory.appendingPathComponent("account-ids.json") }

    /// Lowercased, and only if it is a UUID: an id that does not parse is not
    /// an identity, and a wrong one is worse than none.
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: trimmed) != nil else { return nil }
        return trimmed.lowercased()
    }

    static func load(from url: URL? = nil) -> [UUID: String] {
        guard let data = try? Data(contentsOf: url ?? file),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        var map: [UUID: String] = [:]
        for (local, remote) in raw {
            if let id = UUID(uuidString: local), let value = normalize(remote) { map[id] = value }
        }
        return map
    }

    static func remember(_ localID: UUID, accountId raw: String?, at url: URL? = nil) {
        guard let value = normalize(raw) else { return }
        let target = url ?? file
        var map = load(from: target)
        guard map[localID] != value else { return }
        map[localID] = value
        let out = Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try? AtomicFile.write(data, to: target, mode: 0o600)
    }
}

/// Learns the account UUID of accounts that predate this feature, once, from
/// the profile endpoint, with an access token the vault already holds. A miss
/// is retried no more than every half hour, so a profile outage is not a new
/// request every poll.
actor IdentityResolver {
    static let retryAfter: TimeInterval = 30 * 60
    private var lastTried: [UUID: Date] = [:]

    func resolveIfMissing(_ account: Account, vault: TokenVault, now: Date = Date()) async {
        guard AccountIdentity.load()[account.id] == nil else { return }
        if let last = lastTried[account.id], now.timeIntervalSince(last) < Self.retryAfter { return }
        lastTried[account.id] = now
        guard let token = try? await vault.accessToken(for: account),
              let profile = try? await OAuth.fetchProfile(accessToken: token)
        else { return }
        AccountIdentity.remember(account.id, accountId: profile.accountId)
    }
}

// MARK: - Labels at promote

/// A label is the letter under a gauge and the handle agents pass as
/// `--account`. Two accounts sharing one makes both ambiguous (the guard
/// refuses) and makes Slack titles unreadable, so promote never lets a
/// duplicate through. Pure, so the selftest pins it.
enum PromoteLabels {
    static func isFree(_ label: String, taken: Set<String>) -> Bool {
        guard let normalized = Account.normalizeLabel(label) else { return false }
        return !taken.contains(normalized)
    }

    /// The server's own label for this account when it is free, then the
    /// nickname's first letter, then the first free A–Z.
    static func freeDefault(preferred: String?, nickname: String, taken: Set<String>) -> String {
        var candidates: [String] = []
        if let preferred, let p = Account.normalizeLabel(preferred) { candidates.append(p) }
        candidates.append(Account.defaultLabel(for: nickname))
        candidates += "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
        return candidates.first { $0 != "?" && !taken.contains($0) } ?? "?"
    }
}

// MARK: - Before every pass

/// "Am I still the server?" — asked at the start of every poll pass, before a
/// single request reaches Anthropic.
///
/// Once per PASS, not per account: a pass spans a few seconds across the
/// accounts, and demotion only ever stops a machine spending its OWN tokens
/// (each machine holds its own sign-ins), so a check per pass closes the gap
/// that matters without tripling the read rate. The 409 on push stays as a
/// second fence behind it.
///
///   no web key          → cannot ask; the remembered role decides (today: poll)
///   live answer         → it wins (server or unelected poll; follower does not)
///   web unreachable     → the remembered role decides: a remembered follower
///                         never polls, and a remembered server is not stopped
///                         by a blip
enum PrePass {
    static func mayPoll(hasKey: Bool, live: Election?, remembered: RoleMemory.Stance?) -> Bool {
        guard hasKey else { return remembered != .follower }
        return StartupRole.mayPoll(live: live, remembered: remembered)
    }
}
