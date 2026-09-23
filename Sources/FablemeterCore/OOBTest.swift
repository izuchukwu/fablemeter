import Foundation

/// `--oob-test` / `fablemeter-server oob-test`: prove the paste-back sign-in
/// end to end without keeping anything. The code is exchanged for real, and
/// the tokens that come back are counted and dropped — never written, never
/// printed — so no running app can ever pick one up.
enum OOBTest {
    static func run() async -> Int32 {
        let attempt = OOB.begin()
        print("oob-test: open this on any device, approve, and paste the code the page shows:\n")
        print(attempt.url.absoluteString)
        print("\npaste code: ", terminator: "")
        fflush(stdout)
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            print("oob-test: FAIL — nothing pasted")
            return 1
        }
        do {
            let result = try await OOB.complete(attempt, pasted: line)
            print("oob-test: PASS — exchange accepted, refresh token received (\(result.refreshToken.count) chars, discarded), account \(result.email), account id \(result.accountId == nil ? "ABSENT" : "present")")
            return 0
        } catch let error as OAuthError {
            // `errorDescription` carries at most a 200-byte response prefix for
            // the operator's terminal; it never contains a token.
            print("oob-test: FAIL — \(error.errorDescription ?? error.displayText)")
            return 1
        } catch {
            print("oob-test: FAIL — \(NetworkFailure.text(for: error) ?? NetworkFailure.genericText)")
            return 1
        }
    }
}
