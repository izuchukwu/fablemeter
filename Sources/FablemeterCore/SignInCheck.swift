import Foundation

/// Who a fresh sign-in turned out to be, measured against the row it was for.
///
/// Decided BEFORE anything is written. A sign-in spends an authorization code,
/// never the stored refresh token, so a sign-in that turns out to be the wrong
/// account can be thrown away and the row keeps a credential that still works.
/// Written first and checked second, a browser still signed into Personal while
/// "Signing into Charm (2 of 3)" overwrote Charm's only token and left the C row
/// reporting Personal's usage under Charm's name, which `fablemeter --guard
/// --account C` then judged clear while the real Charm was blocked.
enum SignInCheck {
    /// The address the app stored when a browser sign-in could not learn one.
    static let placeholderEmail = "Claude account"

    struct Row: Equatable {
        let id: UUID
        let accountId: String?
        let email: String
    }

    enum Verdict: Equatable {
        /// The account the row was meant for: persist into it.
        case match
        /// Nothing was ever known about the row (no account id, no real
        /// address), so this first identified sign-in is what defines it. Also
        /// the answer for Add Account when the account is not already here.
        case establish
        /// Another row here already holds this account. Its token belongs
        /// there; the row it was meant for is left exactly as it was.
        case belongsTo(UUID)
        /// A different account that no row here holds: discarded.
        case mismatch
        /// The sign-in said nothing that can be checked against the row: refused.
        case unidentified
    }

    static func isRealEmail(_ email: String?) -> Bool {
        guard let email else { return false }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != placeholderEmail
    }

    static func sameEmail(_ a: String, _ b: String) -> Bool {
        ActiveAccount.normalize(a) == ActiveAccount.normalize(b)
    }

    /// The row, other than `excluding`, that holds this account: by account id
    /// first; by address only where one side never learned an id.
    static func owner(accountId: String?, email: String?, in rows: [Row], excluding: UUID?) -> UUID? {
        let others = rows.filter { $0.id != excluding }
        if let accountId, let hit = others.first(where: { $0.accountId == accountId }) { return hit.id }
        guard let email, isRealEmail(email) else { return nil }
        return others.first(where: {
            ($0.accountId == nil || accountId == nil) && isRealEmail($0.email) && sameEmail($0.email, email)
        })?.id
    }

    /// `target` nil is Add Account: a new row, so the only question is whether
    /// the account is already here.
    static func verdict(target: Row?, accountId rawId: String?, email rawEmail: String?, rows: [Row]) -> Verdict {
        let accountId = AccountIdentity.normalize(rawId)
        let email = isRealEmail(rawEmail) ? rawEmail : nil
        guard accountId != nil || email != nil else { return .unidentified }
        let elsewhere = owner(accountId: accountId, email: email, in: rows, excluding: target?.id)
        guard let target else { return elsewhere.map { .belongsTo($0) } ?? .establish }

        let same: Bool?
        if let known = target.accountId, let got = accountId {
            same = known == got
        } else if target.accountId != nil {
            // The row's id is known but this sign-in carried none: only an
            // address both sides really have can stand in for it.
            if let email, isRealEmail(target.email) { same = sameEmail(target.email, email) } else { same = nil }
        } else if isRealEmail(target.email) {
            same = email.map { sameEmail(target.email, $0) }
        } else {
            // Nothing was ever known about this row: the first identified
            // sign-in defines it, unless it is an account another row holds.
            return elsewhere.map { .belongsTo($0) } ?? .establish
        }
        switch same {
        case .some(true): return .match
        case .some(false): return elsewhere.map { .belongsTo($0) } ?? .mismatch
        case .none: return .unidentified
        }
    }
}

extension CoreChecks {
    // MARK: Sign-in identity, decided before anything is written

    static func signInIdentity(_ check: Check) {
        let personal = "5b2d6c1e-9f1a-4c3b-8e7d-2a1b3c4d5e6f"
        let charm = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
        let stranger = "11111111-2222-4333-8444-555555555555"
        let p = SignInCheck.Row(id: UUID(), accountId: personal, email: "izu@personal.test")
        let c = SignInCheck.Row(id: UUID(), accountId: charm, email: "izu@charm.test")
        let rows = [p, c]
        func verdict(_ target: SignInCheck.Row?, _ id: String?, _ email: String?, _ rows: [SignInCheck.Row] = rows) -> SignInCheck.Verdict {
            SignInCheck.verdict(target: target, accountId: id, email: email, rows: rows)
        }

        check("sign-in: the account the row was for matches by id",
              verdict(c, charm, "izu@charm.test") == .match, "")
        check("sign-in: id match ignores case",
              verdict(c, charm.uppercased(), nil) == .match, "")
        check("sign-in: signing into Personal while meaning Charm belongs to the Personal row, never Charm's",
              verdict(c, personal, "izu@personal.test") == .belongsTo(p.id), "")
        check("sign-in: an account no row holds is a mismatch, not a write",
              verdict(c, stranger, "who@else.test") == .mismatch, "")
        check("sign-in: a sign-in with neither id nor address is refused",
              verdict(c, nil, nil) == .unidentified, "")
        check("sign-in: the placeholder address counts as no address",
              verdict(c, nil, SignInCheck.placeholderEmail) == .unidentified, "")
        check("sign-in: a malformed id counts as no id",
              verdict(c, "not-a-uuid", nil) == .unidentified, "")

        let byEmail = SignInCheck.Row(id: UUID(), accountId: nil, email: "izu@charm.test")
        check("sign-in: a row with only a real address matches on the address",
              verdict(byEmail, charm, "IZU@charm.test ", [p, byEmail]) == .match, "")
        check("sign-in: a row with only a real address refuses another address",
              verdict(byEmail, personal, "izu@personal.test", [p, byEmail]) == .belongsTo(p.id), "")
        check("sign-in: a row whose id is known cannot be matched by a sign-in with no id and no real address",
              verdict(c, nil, SignInCheck.placeholderEmail) == .unidentified, "")
        check("sign-in: a row whose id is known matches an id-less sign-in on its real address",
              verdict(c, nil, "izu@charm.test") == .match, "")

        let blank = SignInCheck.Row(id: UUID(), accountId: nil, email: SignInCheck.placeholderEmail)
        check("sign-in: a row nothing was known about is established by its first identified sign-in",
              verdict(blank, stranger, "who@else.test", [p, blank]) == .establish, "")
        check("sign-in: …but not with an account another row already holds",
              verdict(blank, personal, nil, [p, blank]) == .belongsTo(p.id), "")
        check("sign-in: …and an unidentified sign-in still defines nothing",
              verdict(blank, nil, nil, [p, blank]) == .unidentified, "")

        check("add account: a new account is established",
              verdict(nil, stranger, "who@else.test") == .establish, "")
        check("add account: an account already here by id is refused as a duplicate",
              verdict(nil, charm, "different@address.test") == .belongsTo(c.id), "")
        check("add account: an account already here by address (no id either side) is refused as a duplicate",
              verdict(nil, nil, "izu@charm.test", [SignInCheck.Row(id: c.id, accountId: nil, email: "izu@charm.test")]) == .belongsTo(c.id), "")
        check("add account: an unidentified sign-in is refused, never stored under a placeholder",
              verdict(nil, nil, nil) == .unidentified, "")
    }
}
