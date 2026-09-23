import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// The machine-key handoff with the web companion, shared by the menu bar
/// app's loopback flow and the headless paste-back one. One implementation of
/// the exchange and of the randomness behind the state value, so the two
/// flows cannot drift apart.
enum WebConnect {
    static let webBase = URL(string: "https://fablemeter.oniconic.app")!

    /// The state value is the connect flow's whole defence against a page
    /// guessing at the loopback port, so its entropy source gets no silent
    /// fallback: a failure refuses the attempt before a listener ever binds.
    static func randomHex(
        bytes count: Int,
        using source: (Int) -> [UInt8]? = secureRandomBytes
    ) throws -> String {
        guard let buf = source(count), buf.count == count else {
            throw ConnectError.entropyFailed
        }
        return buf.map { String(format: "%02x", $0) }.joined()
    }

    static func secureRandomBytes(_ count: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count)
        #if canImport(Security)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &buf) == errSecSuccess else { return nil }
        #else
        // The platform CSPRNG (getrandom on Linux); it has no failure mode to
        // fall back from.
        var rng = SystemRandomNumberGenerator()
        for i in 0..<count { buf[i] = UInt8.random(in: 0...255, using: &rng) }
        #endif
        return buf
    }

    /// The paste-back connect page: after the owner confirms, the web SHOWS a
    /// one-time code instead of redirecting to 127.0.0.1. It lives five
    /// minutes, because a person carries it by hand.
    static func oobURL(state: String) -> URL {
        var comps = URLComponents(url: webBase.appendingPathComponent("connect"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "mode", value: "oob"),
            URLQueryItem(name: "state", value: state),
        ]
        return comps.url!
    }

    /// Code in, machine key out. The key arrives in a response body and goes
    /// straight to storage; it never transits a URL and is never logged.
    static func exchangeCode(_ code: String) async throws -> String {
        var request = URLRequest(url: webBase.appendingPathComponent("api/exchange"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let (data, response) = try await HTTP.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ConnectError.exchange(status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["key"] as? String, !key.isEmpty
        else { throw ConnectError.malformed }
        return key
    }
}
