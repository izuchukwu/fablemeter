import Foundation

/// Whether the login Fablemeter's CLI saved for an account (the one the
/// cascade and `fablemeter swap` use) still works. This is a different
/// credential from the one the app itself polls with, so an account can read
/// fine here and still be one the cascade refuses to switch to.
///
/// The app never opens the Keychain slot: the CLI judges it and the bundled
/// `fablemeter-saved-login health` helper prints its verdict as JSON keyed by
/// account UUID, with no credential in it.
struct SavedLoginHealth: Equatable {
    enum Status: String { case ok, expired, unreadable, missing }

    let status: Status
    /// The account is the one Claude Code is logged into right now, which
    /// decides how it is reconnected.
    let isLive: Bool

    /// Anything but a working login. `unreadable` and `missing` read the same
    /// to a person: there is no usable saved login, and the fix is the same.
    var isSignedOut: Bool { status != .ok }

    /// Account UUID (lower-cased) to health. Nil when the output is not the
    /// shape the helper prints, so a broken reader shows nothing rather than
    /// guessing; a key that is not a UUID is dropped.
    static func decode(_ data: Data) -> [String: SavedLoginHealth]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["accounts"] as? [String: Any] else { return nil }
        var result: [String: SavedLoginHealth] = [:]
        for (key, value) in accounts {
            guard let id = AccountIdentity.normalize(key),
                  let entry = value as? [String: Any],
                  let raw = entry["status"] as? String,
                  let status = Status(rawValue: raw) else { continue }
            result[id] = SavedLoginHealth(status: status, isLive: entry["live"] as? Bool == true)
        }
        return result
    }

    /// The last line the CLI said, without its own prefix, as the reason a
    /// reconnect failed. Never more than a short line.
    static func failureLine(_ stderr: String) -> String {
        let line = stderr.split(separator: "\n").last.map(String.init) ?? ""
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("fablemeter swap:") { text = String(text.dropFirst("fablemeter swap:".count)).trimmingCharacters(in: .whitespaces) }
        if text.isEmpty { return "Didn't finish" }
        return text.count > 80 ? String(text.prefix(79)) + "…" : text
    }
}

enum ReconnectProgress: Equatable {
    case running(String)
    case failed(String)
    case done
}
