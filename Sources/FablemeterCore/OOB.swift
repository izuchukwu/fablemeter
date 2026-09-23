import Foundation

// MARK: - Out-of-band sign-in

/// The paste-back sign-in, for machines with no browser of their own: the
/// user opens the authorize URL on any device, approves, and the success page
/// shows a code they paste into the terminal. The token exchange then happens
/// HERE, with a PKCE verifier that never left this process, so the refresh
/// token is minted on this machine and on no other.
///
/// Pinned against Claude Code's own client (2.1.281): its manual flow keeps
/// the same authorize URL as the browser flow and changes only the
/// `redirect_uri`, in both the authorize request and the token exchange, to
/// `MANUAL_REDIRECT_URL`. That redirect is registered on this client id
/// precisely because Claude Code uses it.
enum OOB {
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"

    /// One attempt's secrets. Held in memory only; never written anywhere.
    struct Attempt {
        let verifier: String
        let state: String
        let url: URL
    }

    static func begin(
        verifier: String = PKCE.randomBase64URL(bytes: 64),
        state: String = PKCE.randomBase64URL(bytes: 32)
    ) -> Attempt {
        Attempt(verifier: verifier, state: state, url: authorizeURL(challenge: PKCE.challenge(for: verifier), state: state))
    }

    /// Same parameters, in the same order, as the browser flow — only the
    /// redirect differs. Pure, so the selftest pins it.
    static func authorizeURL(challenge: String, state: String) -> URL {
        var comps = URLComponents(string: Constants.authorizeURL)!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Constants.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Constants.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return comps.url!
    }

    enum PasteError: Error, Equatable {
        case empty
        case stateMismatch
        case denied(String)
    }

    /// What the user pasted, reduced to the authorization code.
    ///
    /// Three shapes are accepted because people paste whatever the page gave
    /// them: `code#state` (what the success page shows, and the same packing
    /// the loopback flow receives), a bare `code`, or the whole callback URL
    /// with `?code=&state=`. A state that is present and wrong is refused —
    /// that code belongs to some other attempt. A state that is absent is
    /// accepted, because the code is still worthless without this process's
    /// verifier.
    static func parse(_ pasted: String, expectedState: String) throws -> String {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PasteError.empty }

        var code: String
        var state: String?
        if let comps = URLComponents(string: text), comps.scheme != nil,
           let items = comps.queryItems, !items.isEmpty {
            if let err = items.first(where: { $0.name == "error" })?.value {
                let detail = items.first(where: { $0.name == "error_description" })?.value
                throw PasteError.denied(detail ?? err)
            }
            code = items.first(where: { $0.name == "code" })?.value ?? ""
            state = items.first(where: { $0.name == "state" })?.value
        } else {
            code = text
        }
        if let hash = code.firstIndex(of: "#") {
            state = String(code[code.index(after: hash)...])
            code = String(code[code.startIndex..<hash])
        }
        code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw PasteError.empty }
        if let state, !state.isEmpty, state != expectedState { throw PasteError.stateMismatch }
        return code
    }

    struct SignedIn {
        let email: String
        let refreshToken: String
        /// The Anthropic account UUID, when either response carried it.
        let accountId: String?
    }

    /// Code in, credentials out. The exchange carries the manual redirect —
    /// the server checks it against the authorize request.
    ///
    /// An account whose address cannot be learned is refused, not stored under
    /// a placeholder: a made-up address matches nothing and says so nowhere.
    static func complete(_ attempt: Attempt, pasted: String) async throws -> SignedIn {
        let code: String
        do {
            code = try parse(pasted, expectedState: attempt.state)
        } catch PasteError.stateMismatch {
            throw OAuthError.stateMismatch
        } catch PasteError.denied(let why) {
            throw OAuthError.denied(why)
        } catch {
            throw OAuthError.malformed
        }
        let bundle = try await OAuth.exchange(
            code: code, verifier: attempt.verifier, redirectURI: redirectURI, state: attempt.state
        )
        guard let refresh = bundle.refreshToken else { throw OAuthError.malformed }
        var email = bundle.email
        var accountId = bundle.accountId
        if email?.isEmpty != false || accountId == nil {
            let profile = try? await OAuth.fetchProfile(accessToken: bundle.accessToken)
            if email?.isEmpty != false { email = profile?.email }
            if accountId == nil { accountId = profile?.accountId }
        }
        guard let email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OAuthError.profileUnavailable
        }
        return SignedIn(email: email, refreshToken: refresh, accountId: accountId)
    }
}
