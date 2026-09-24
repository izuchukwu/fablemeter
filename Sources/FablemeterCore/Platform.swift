import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif

// MARK: - Log

/// The app's own log, one subsystem so `log show --predicate 'subsystem ==
/// "com.izu.fablemeter"'` returns this app's lines and nothing else.
///
/// Not `NSLog`: the unified log redacts a dynamic string argument as `<private>`
/// unless the call site says otherwise, so an `NSLog("%@", line)` writes a
/// perfectly formatted diagnostic that nobody can ever read back. `Logger` can
/// mark the interpolation public, and it does not parse the string as a format,
/// so a server-supplied bucket label cannot be read as one either.
///
/// Every call site hands over a finished `String` and the channel marks it
/// public, which is what every call site did before it had to be portable: no
/// line this app writes carries a credential, so none was ever private. Off
/// Apple platforms there is no unified log; lines go to stderr, prefixed, which
/// journald and `fly logs` both capture.
struct LogChannel: Sendable {
    let category: String
    #if canImport(os)
    private let logger: Logger
    #endif

    init(category: String) {
        self.category = category
        #if canImport(os)
        logger = Logger(subsystem: "com.izu.fablemeter", category: category)
        #endif
    }

    func notice(_ message: String) {
        #if canImport(os)
        logger.notice("\(message, privacy: .public)")
        #else
        emit("notice", message)
        #endif
    }

    func error(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #else
        emit("error", message)
        #endif
    }

    #if !canImport(os)
    private func emit(_ level: String, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) [fablemeter:\(category)] \(level): \(message)\n".utf8))
    }
    #endif
}

enum Log {
    static let usage = LogChannel(category: "usage")
    static let store = LogChannel(category: "store")
    static let push = LogChannel(category: "push")
    static let role = LogChannel(category: "role")
}

// MARK: - Lock

/// `Locked` where it exists, an `NSLock` where it does not. Same
/// `withLock` shape either way, so call sites cannot tell which one they have.
final class Locked<State>: @unchecked Sendable {
    private var state: State
    private let lock = NSLock()

    init(initialState: State) { state = initialState }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

// MARK: - HTTP

/// `URLSession.shared.data(for:)` where the async API exists, and a
/// continuation over `dataTask` where it does not. One seam, so every request
/// this app makes behaves the same on both platforms.
enum HTTP {
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let response {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
        #else
        return try await URLSession.shared.data(for: request)
        #endif
    }
}

// MARK: - Machine identity

/// Which machine this is, for the web companion's machine list. A random UUID
/// minted once, rather than the hostname, because hostnames collide and get
/// renamed and the server role must follow the machine, not its name.
///
/// It lives in `~/.claude/fablemeter/`, beside the fleet's state file, and
/// deliberately NOT in the account store's directory: nothing new ever goes in
/// the directory that holds the refresh tokens.
/// Machine ids have exactly one spelling: lowercase. Foundation mints UUIDs in
/// uppercase and the web stores them lowercased, so any comparison between an
/// id this machine holds and one the web returned is only correct after both
/// pass through here. Normalize at the boundary (minting, reading the file,
/// decoding a web answer) and compare with `same` everywhere else.
enum MachineID {
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// False when either side is missing: an absent id never matches, so a
    /// machine can never conclude it is the server from a nil.
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let x = normalize(a), y = normalize(b)
        return !x.isEmpty && x == y
    }
}

enum MachineIdentity {
    static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        return Home.directory.appendingPathComponent(".claude/fablemeter", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("machine-id") }

    /// The stored id, minted on first use. A file that exists but does not hold
    /// a UUID is replaced rather than trusted: an id is only useful if it parses.
    static func id() -> String {
        if let raw = try? String(contentsOf: file, encoding: .utf8),
           let parsed = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            // The file may hold the uppercase spelling older builds wrote; it is
            // the same id, read in the one spelling. Never rewritten, so this
            // machine stays the machine the web already knows.
            return MachineID.normalize(parsed.uuidString)
        }
        let fresh = MachineID.normalize(UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try? AtomicFile.write(Data((fresh + "\n").utf8), to: file, mode: 0o644)
        return fresh
    }

    /// How the machine list names this machine.
    static var displayName: String {
        #if os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
}

// MARK: - Home

enum Home {
    /// The user's home. On Linux Foundation answers from the passwd entry and
    /// ignores `$HOME`, while the `fablemeter` helper and Claude Code's own
    /// `~/.claude.json` go by `$HOME` — so there `$HOME` wins, or a service
    /// user with a relocated home would write its state where nothing reads
    /// it. On macOS nothing changes.
    static var directory: URL {
        #if os(Linux)
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
