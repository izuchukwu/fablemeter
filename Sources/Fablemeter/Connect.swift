import AppKit
@testable import FablemeterCore
import Foundation
import Security

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

    /// The state is the whole defense against a malicious local page, so its
    /// entropy source is not allowed to degrade quietly: if the system refuses
    /// to hand over random bytes, the connect attempt refuses to exist rather
    /// than proceeding on a weaker substitute. Injectable so the selftest can
    /// prove the refusal without breaking the real source.
    static func randomHex(
        bytes count: Int,
        using source: (Int) -> [UInt8]? = WebConnect.secureRandomBytes
    ) throws -> String {
        try WebConnect.randomHex(bytes: count, using: source)
    }

    /// `nil` on failure — never a substitute.
    static func secureRandomBytes(_ count: Int) -> [UInt8]? {
        WebConnect.secureRandomBytes(count)
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
        let state = try randomHex(bytes: 16)
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
        try await WebConnect.exchangeCode(code)
    }
}
