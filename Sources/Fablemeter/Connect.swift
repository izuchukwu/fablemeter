import AppKit
import Foundation
import Security

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

    var errorDescription: String? { displayText }

    var displayText: String {
        switch self {
        case .timedOut: return "connect timed out"
        case .stateMismatch: return "connect aborted"
        case .missingCode: return "connect refused"
        case .exchange(let code): return "connect failed (\(code))"
        case .malformed: return "unexpected response"
        case .storeFailed: return "could not store the key"
        }
    }
}

// MARK: - Push key storage

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
/// connect flow. A successful connect writes the Keychain, which then wins.
struct PushKeyStore {
    var readKeychain: () -> String?
    var writeKeychain: (String) -> Bool
    var readFile: () -> String?

    func currentKey() -> String? { readKeychain() ?? readFile() }

    static let service = "com.izu.fablemeter"
    static let account = "push-key"

    static let standard = PushKeyStore(
        readKeychain: { Keychain.read(service: service, account: account) },
        writeKeychain: { Keychain.write($0, service: service, account: account) },
        readFile: {
            let file = Store.directory.appendingPathComponent("push-secret.txt")
            let raw = try? String(contentsOf: file, encoding: .utf8)
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
    )
}

// MARK: - Connect flow

/// The web companion's localhost handoff: the site mints a one-time exchange
/// code and hands it to a listener that exists only for the moment of the
/// redirect. The push key itself never transits a URL — a query parameter
/// lands in browser history; the sixty-second single-use code is the only
/// thing that does, and it is spent the moment it is exchanged.
///
/// Built on the sign-in's own `LoopbackCallback`, and bound by the same two
/// rules that hold that flow together: teardown is awaited before the
/// exchange begins, and an abandoned handoff times out rather than wedging.
/// The one difference is the port — connect binds an ephemeral one and
/// advertises whatever the kernel assigned, because unlike the OAuth
/// redirect no third party had to be told the port in advance.
enum Connect {
    static let webBase = URL(string: "https://fablemeter.oniconic.app")!
    static let timeout: TimeInterval = 300

    static func randomHex(bytes count: Int) -> String {
        var buf = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &buf) != errSecSuccess {
            for i in 0..<count { buf[i] = UInt8.random(in: 0...255) }
        }
        return buf.map { String(format: "%02x", $0) }.joined()
    }

    /// Pure, so the selftest can pin the shape the site expects.
    static func connectURL(port: UInt16, state: String) -> URL {
        var comps = URLComponents(
            url: webBase.appendingPathComponent("connect"), resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "state", value: state),
        ]
        return comps.url!
    }

    /// Pure validation: an answer whose state does not match was not minted
    /// for this flow, whoever sent it, and a callback with no code has
    /// nothing to exchange.
    static func code(from params: [String: String], expecting state: String) throws -> String {
        guard params["state"] == state else { throw ConnectError.stateMismatch }
        guard let code = params["code"], !code.isEmpty else { throw ConnectError.missingCode }
        return code
    }

    /// The full handoff. Everything injectable is injected so the selftest can
    /// drive it end to end with the site played by a closure; the defaults are
    /// the real thing.
    ///
    /// The state value is the defense that matters here: the repo is public,
    /// so the port scheme is public, and any web page the user happens to have
    /// open can fire requests at 127.0.0.1. The listener itself refuses a
    /// callback whose state is not the one this attempt generated — answered
    /// as a stranger, without consuming the attempt — so a guesser cannot
    /// burn the handoff, let alone complete it. The `code(from:expecting:)`
    /// check below is belt to that braces.
    static func run(
        timeout: TimeInterval = Connect.timeout,
        exchange: @escaping @Sendable (String) async throws -> String = { try await exchangeCode($0) },
        store: PushKeyStore = .standard,
        open: @escaping @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) async throws {
        let state = randomHex(bytes: 16)
        let params: [String: String]
        do {
            params = try await LoopbackCallback.withServer(
                ports: [0],
                successText: "Connected — you can close this tab.",
                expectedState: state
            ) { server in
                open(connectURL(port: server.boundPort, state: state))
                return try await OAuth.firstOf(timeout: timeout) {
                    try await server.awaitCallback()
                }
            }
        } catch OAuthError.timedOut {
            throw ConnectError.timedOut
        } catch is CancellationError {
            throw ConnectError.timedOut
        }
        // The listener is gone; only now does anything leave the machine.
        let code = try code(from: params, expecting: state)
        let key = try await exchange(code)
        guard store.writeKeychain(key) else { throw ConnectError.storeFailed }
    }

    static func exchangeCode(_ code: String) async throws -> String {
        var request = URLRequest(url: webBase.appendingPathComponent("api/exchange"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ConnectError.exchange(status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["key"] as? String, !key.isEmpty
        else { throw ConnectError.malformed }
        return key
    }
}
