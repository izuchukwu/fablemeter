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

    /// Re-order what is on disk to match the order the app is showing, without
    /// carrying anything else across from it. Ids the file has and the order
    /// does not (an account added by another instance) settle at the end.
    static func sorted(_ accounts: [Account], by order: [UUID]) -> [Account] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return accounts.enumerated()
            .sorted { left, right in
                let a = rank[left.element.id] ?? (order.count + left.offset)
                let b = rank[right.element.id] ?? (order.count + right.offset)
                return a < b
            }
            .map(\.element)
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

enum FileError: LocalizedError {
    case syscall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .syscall(let op, let code):
            return "\(op) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Write-then-rename with the bytes forced to the disk *before* the rename, so
/// a process that dies at any instant leaves either the whole old file or the
/// whole new one. `Data.write(options: .atomic)` renames but never flushes; a
/// refresh token that only reached the page cache is a token that can be
/// consumed server-side and then lost, which is exactly what bricks an account.
enum AtomicFile {
    static func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw FileError.syscall("create", errno) }
        var committed = false
        defer { if !committed { unlink(temporary.path) } }

        do {
            guard fchmod(fd, mode) == 0 else { throw FileError.syscall("chmod", errno) }
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(
                        fd, raw.baseAddress!.advanced(by: offset), raw.count - offset
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw FileError.syscall("write", errno)
                    }
                    offset += written
                }
            }
            // F_FULLFSYNC pushes past the drive's own write cache; plain fsync
            // only reaches it. Either is enough to survive a killed process.
            if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
                throw FileError.syscall("fsync", errno)
            }
        } catch {
            close(fd)
            throw error
        }
        close(fd)

        guard rename(temporary.path, url.path) == 0 else {
            throw FileError.syscall("rename", errno)
        }
        committed = true

        // The rename is only durable once the directory entry itself is flushed.
        let dir = open(directory.path, O_RDONLY)
        if dir >= 0 {
            _ = fsync(dir)
            close(dir)
        }
    }
}

/// Cross-process guard on one account's refresh.
///
/// In-process single-flight cannot see a *second copy of the app* refreshing the
/// same account, and a second copy is a second consumer of a token that only
/// survives being spent once. `flock` is advisory but process-wide, and the
/// kernel drops it when the holder dies — which is exactly the lifetime wanted
/// here, since the holder dying is the case being defended against.
final class RefreshLock: @unchecked Sendable {
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// Throws `OAuthError.refreshBusy` when another process holds the lock.
    /// Returns `nil` when locking is simply unavailable — a lock file that
    /// cannot be created must never stop the app refreshing.
    static func acquire(for id: UUID, in directory: URL) throws -> RefreshLock? {
        let path = directory.appendingPathComponent(".refresh-\(id.uuidString).lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return nil }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let busy = errno == EWOULDBLOCK
            close(descriptor)
            if busy { throw OAuthError.refreshBusy }
            return nil
        }
        return RefreshLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}

/// Plaintext-on-disk account store. Deliberately not the Keychain: this app is
/// ad-hoc signed, so every rebuild changes the signature and macOS would prompt
/// for keychain access on each launch.
///
/// Disk — not the in-memory account array — is the authority on refresh tokens.
/// Every mutation is therefore a load-modify-save against the file (`mutate`),
/// never a blind write of a snapshot some other part of the app has been holding
/// on to: a rotated token that landed on disk a second ago must not be undone by
/// a rename or a reorder carrying a stale copy of it.
enum Store {
    static let maxAccounts = 3

    /// Only `--selftest` sets this, so a real save/load round-trip can run
    /// against a temporary file instead of the user's own.
    static var directoryOverride: URL?

    /// Still `ClaudeUsageBar`, after the app itself became Claude Battery, and
    /// that is deliberate. Nobody sees this path, so renaming it buys nothing —
    /// and what it costs is a migration of the only copy of every account's
    /// refresh token. `--selftest` pins the name so it cannot drift by accident.
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

    /// Full write. Throws rather than logging: every caller here is persisting a
    /// credential, and a swallowed failure is an account nobody can recover.
    static func save(_ accounts: [Account]) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        try AtomicFile.write(try enc.encode(accounts), to: file, mode: 0o600)
    }

    /// The only way anything mutates the file: read what is actually there,
    /// change it, write it back.
    static func mutate(_ body: (inout [Account]) -> Void) throws {
        var accounts = load()
        let before = accounts
        body(&accounts)
        guard accounts != before else { return }
        try save(accounts)
    }

    /// Persist a rotated refresh token immediately — losing it bricks the
    /// account. `replacing` makes it a compare-and-swap: a rotation is only
    /// written while the token it replaces is still the one on disk, so a
    /// straggling refresh can never stamp on a token an interactive sign-in put
    /// there in the meantime.
    static func updateRefreshToken(id: UUID, to token: String, replacing expected: String? = nil) throws {
        try mutate { accounts in
            guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
            if let expected, accounts[idx].refreshToken != expected { return }
            accounts[idx].refreshToken = token
        }
    }
}
