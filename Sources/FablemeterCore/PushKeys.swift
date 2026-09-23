import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - Errors

/// Same two-layer shape as `OAuthError`: the case may carry detail for the
/// log, `displayText` is the only form that reaches the screen.
enum ConnectError: LocalizedError, Equatable {
    case timedOut
    case stateMismatch
    case missingCode
    case exchange(Int)
    case malformed
    case storeFailed
    case entropyFailed

    var errorDescription: String? { displayText }

    var displayText: String {
        switch self {
        case .timedOut: return "connect timed out"
        case .stateMismatch: return "connect aborted"
        case .missingCode: return "connect refused"
        case .exchange(let code): return "connect failed (\(code))"
        case .malformed: return "unexpected response"
        case .storeFailed: return "could not store the key"
        case .entropyFailed: return "secure randomness unavailable"
        }
    }
}

#if canImport(Security)
enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    @discardableResult
    static func write(_ value: String, service: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Where the push key lives. Keychain first — the home a key minted for a
/// stranger's machine deserves — then the pre-connect `push-secret.txt`, so a
/// Mac that was provisioned by hand keeps pushing without ever running the
#endif

/// The same contract as the Keychain helper, as a 0600 file inside the account
/// store's own 0700 directory. Used where there is no Keychain (Linux), so a
/// headless server keeps its push key beside the credentials it already
/// guards, never beside anything the fleet reads.
enum KeyFile {
    static func file(named name: String) -> URL {
        Store.directory.appendingPathComponent(name)
    }

    static func read(_ name: String) -> String? {
        let raw = try? String(contentsOf: file(named: name), encoding: .utf8)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    @discardableResult
    static func write(_ value: String, named name: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: Store.directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try AtomicFile.write(Data(value.utf8), to: file(named: name), mode: 0o600)
            return true
        } catch {
            return false
        }
    }
}

/// connect flow. A successful connect writes the Keychain, which then wins.
struct PushKeyStore {
    var readKeychain: () -> String?
    var writeKeychain: (String) -> Bool
    var readFile: () -> String?

    func currentKey() -> String? { readKeychain() ?? readFile() }

    static let service = "com.izu.fablemeter"
    static let account = "push-key"

    /// Reassigned only by `fablemeter-server` on macOS, which must never share
    /// the menu bar app's Keychain item — see `dataDirectory`.
    static var standard = PushKeyStore(
        readKeychain: {
            #if canImport(Security)
            Keychain.read(service: service, account: account)
            #else
            KeyFile.read("push-key")
            #endif
        },
        writeKeychain: {
            #if canImport(Security)
            Keychain.write($0, service: service, account: account)
            #else
            KeyFile.write($0, named: "push-key")
            #endif
        },
        readFile: {
            let file = Store.directory.appendingPathComponent("push-secret.txt")
            let raw = try? String(contentsOf: file, encoding: .utf8)
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
    )
}

extension PushKeyStore {
    /// Files in the account store's own directory, never the Keychain. What
    /// `fablemeter-server` uses on macOS: a key minted for the server must not
    /// overwrite the menu bar app's, or the web would see one machine where
    /// there are two.
    static var dataDirectory: PushKeyStore {
        PushKeyStore(
            readKeychain: { KeyFile.read("push-key") },
            writeKeychain: { KeyFile.write($0, named: "push-key") },
            readFile: { KeyFile.read("push-secret.txt") }
        )
    }
}
