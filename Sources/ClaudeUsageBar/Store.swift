import Foundation

struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    var email: String
    /// Display name. Defaults to the email's local part.
    var nickname: String
    /// Single character drawn under the menu bar gauge.
    var label: String
    var refreshToken: String
    var addedAt: Date

    init(
        id: UUID = UUID(),
        email: String,
        nickname: String? = nil,
        label: String? = nil,
        refreshToken: String,
        addedAt: Date = Date()
    ) {
        let local = Account.localPart(of: email)
        self.id = id
        self.email = email
        self.nickname = nickname.flatMap(Account.normalizeNickname) ?? local
        self.label = label.flatMap(Account.normalizeLabel) ?? Account.defaultLabel(for: local)
        self.refreshToken = refreshToken
        self.addedAt = addedAt
    }

    /// Tolerant of files written before `nickname`/`label` existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let email = try c.decode(String.self, forKey: .email)
        let local = Account.localPart(of: email)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.email = email
        self.refreshToken = try c.decode(String.self, forKey: .refreshToken)
        self.addedAt = (try? c.decode(Date.self, forKey: .addedAt)) ?? Date()
        self.nickname = (try? c.decode(String.self, forKey: .nickname))
            .flatMap(Account.normalizeNickname) ?? local
        self.label = (try? c.decode(String.self, forKey: .label))
            .flatMap(Account.normalizeLabel) ?? Account.defaultLabel(for: local)
    }

    var character: Character { label.first ?? "?" }

    static func localPart(of email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        guard let first = local.first else { return "Account" }
        return first.uppercased() + local.dropFirst()
    }

    static func defaultLabel(for local: String) -> String {
        String(local.first(where: \.isLetter).map { Character($0.uppercased()) } ?? "?")
    }

    static func normalizeLabel(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        return String(first).uppercased()
    }

    static func normalizeNickname(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(32))
    }
}

/// Menu bar order is the account array's own order — there is no separate index
/// to keep in sync — so every reorder is a pure transform of that array.
/// Returning `nil` for a move that cannot happen is what disables the matching
/// menu item.
enum AccountOrder {
    /// Shift `id` by `delta` places; negative moves it towards the front, which
    /// is towards the left of the menu bar cluster.
    static func shifted(_ accounts: [Account], id: UUID, by delta: Int) -> [Account]? {
        guard delta != 0, let from = accounts.firstIndex(where: { $0.id == id }) else { return nil }
        let to = from + delta
        guard to >= 0, to < accounts.count else { return nil }
        var out = accounts
        out.insert(out.remove(at: from), at: to)
        return out
    }

    /// Drop `id` into `targetID`'s slot; everything between it and its old slot
    /// shuffles along by one.
    static func moved(_ accounts: [Account], id: UUID, onto targetID: UUID) -> [Account]? {
        guard id != targetID,
              let from = accounts.firstIndex(where: { $0.id == id }),
              let to = accounts.firstIndex(where: { $0.id == targetID })
        else { return nil }
        var out = accounts
        out.insert(out.remove(at: from), at: to)
        return out
    }
}

/// Plaintext-on-disk account store. Deliberately not the Keychain: this app is
/// ad-hoc signed, so every rebuild changes the signature and macOS would prompt
/// for keychain access on each launch.
enum Store {
    static let maxAccounts = 3

    /// Only `--selftest` sets this, so a real save/load round-trip can run
    /// against a temporary file instead of the user's own.
    static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsageBar", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("accounts.json") }

    static func load() -> [Account] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Account].self, from: data)) ?? []
    }

    static func save(_ accounts: [Account]) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted]
            let data = try enc.encode(accounts)
            try data.write(to: file, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            NSLog("ClaudeUsageBar: failed to save accounts: \(error.localizedDescription)")
        }
    }

    /// Persist a rotated refresh token immediately — losing it bricks the account.
    static func updateRefreshToken(id: UUID, to token: String) {
        var accounts = load()
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        guard accounts[idx].refreshToken != token else { return }
        accounts[idx].refreshToken = token
        save(accounts)
    }
}
