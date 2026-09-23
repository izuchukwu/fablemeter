import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Model

struct UsageBucket: Identifiable, Hashable {
    let id: String
    let label: String
    /// The server's reading, kept optional all the way through: `nil` means the
    /// server did not report this window, `0` means it reported that nothing has
    /// been used. Collapsing the two — which this used to do — throws away the
    /// only bit that separates "I don't know" from "you're fine", and every
    /// state below is decided by that bit.
    let percent: Double?
    let resetsAt: Date?

    /// The server gave us a reading. Not "the reading is interesting": a
    /// reported `0` with no open window is a real answer — nothing used, so the
    /// whole window is still there — and it must count as data, or an account
    /// that has simply not been used reads as an account we know nothing about.
    var hasData: Bool { percent != nil }

    init(id: String, label: String, percent: Double?, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

struct UsageSnapshot {
    var fiveHour: UsageBucket?
    var weekly: UsageBucket?
    /// Every `weekly_scoped` bucket found, in API order.
    var scoped: [UsageBucket] = []
    var fetchedAt: Date = Date()
    /// Diagnostics, never drawn: every `kind` string `limits[]` actually
    /// carried, in API order, including kinds this app does not model. It is the
    /// difference between "the server reported nothing" and "the server reported
    /// something we did not recognise" — two payloads that look identical once
    /// decoded, and only one of which is a bug here.
    var limitKinds: [String] = []
    /// The flat top-level keys had to stand in because `limits[]` was missing or
    /// carried nothing usable. Also diagnostics only.
    var usedFlatKeys = false

    func scoped(named name: String) -> UsageBucket? {
        scoped.first { $0.label.caseInsensitiveCompare(name) == .orderedSame }
    }

    var fable: UsageBucket? { scoped(named: "Fable") }

    /// Fable's week is spent — the bucket is *there* and it is at 100%.
    ///
    /// The distinction that matters is exhausted versus unknown. The API nulls
    /// these keys routinely, and a bucket it did not report says nothing about
    /// whether Fable is available: it is simply not a reading. So an absent
    /// bucket, and a present one whose percent came back null, are both *not*
    /// exhaustion — only a reported reading that has used everything is.
    var isFableExhausted: Bool {
        guard let percent = fable?.percent else { return false }
        return percent >= 100
    }

    /// The single number the menu bar draws: how much room is left before the
    /// tightest window still worth measuring blocks you. A bucket the API did
    /// not report is not a constraint, so it is skipped rather than counted as 0
    /// or 100 — but a bucket it reported as `0` is a constraint of a whole
    /// window, and counts. `nil` means the server reported no readings at all,
    /// which is the no-data state, not "full" and not "empty".
    ///
    /// Once Fable is exhausted it stops being a constraint too, and drops out of
    /// the minimum entirely: an account with no Fable left but a whole session
    /// and a whole week in hand is not blocked, it is a non-Fable account, and
    /// this is the number that says so. The letter's colour is what carries
    /// *which* of the two this is — see `BarRenderer.glyphColor`.
    var headroom: Double? { headroom(fableFirst: true) }

    /// The same minimum under either policy. Fable-first is the default and is
    /// everything above: Fable counts until it is spent, then drops out and the
    /// letter goes yellow to say so. With Fable-first off, Fable was never in
    /// the minimum to begin with — the gauge answers "can I use this account",
    /// not "can I use Fable in it" — so there is no falling-back moment and
    /// nothing for yellow to announce.
    ///
    /// Leaving a bucket out by *policy* is not the same fact as the server not
    /// reporting it: the Fable reading is still decoded, still logged, still on
    /// its own row in the popover. Only this minimum stops consulting it.
    func headroom(fableFirst: Bool) -> Double? {
        let measured = fableFirst && !isFableExhausted
            ? [fiveHour, weekly, fable]
            : [fiveHour, weekly]
        let remaining = measured
            .compactMap { $0?.percent }
            .map { 100 - $0 }
        guard let tightest = remaining.min() else { return nil }
        return max(0, min(100, tightest))
    }
}

// MARK: - Structural logging

/// One line per account per successful poll — so about three lines every five
/// minutes — describing the *shape* of what came back rather than the fact that
/// something did.
///
/// It exists because the states this app draws are decided by distinctions that
/// a decoded snapshot hides: a bucket the server never sent, a bucket it sent
/// with a null percent, and a bucket it sent as a real zero all used to end up
/// looking identical, and telling them apart after the fact meant spending a
/// live request — which costs a single-use refresh token. So the poll that
/// already happened says which one it was.
///
/// The usage payload carries no credential: percentages, reset stamps and model
/// display names. Nothing from `accounts.json` goes in here — the account is
/// named by its one-character menu bar label and nothing else.
enum UsageLog {
    static func line(label: Character, snapshot: UsageSnapshot) -> String {
        var parts = ["usage [\(label)]"]
        parts.append("kinds=" + (snapshot.limitKinds.isEmpty
            ? "none" : snapshot.limitKinds.joined(separator: ",")))
        if snapshot.usedFlatKeys { parts.append("flat-keys") }
        parts.append(field("5-hour", snapshot.fiveHour))
        parts.append(field("weekly", snapshot.weekly))
        if snapshot.scoped.isEmpty {
            parts.append("scoped=none")
        } else {
            parts.append(contentsOf: snapshot.scoped.map { field($0.label, $0) })
        }
        parts.append("headroom=" + (snapshot.headroom.map(number) ?? "none"))
        return parts.joined(separator: " ")
    }

    /// One line per account per *failed* poll, in the same shape as `line` so
    /// the two interleave readably. It carries the verdict the popover is
    /// showing, which ladder the failure was routed onto, and how deep into that
    /// ladder the account now is — enough to reconstruct, after the fact, that
    /// three accounts failed together at one moment rather than one account
    /// losing its data.
    ///
    /// `message` has already been through `AppState.outcome(for:)`, which is the
    /// only thing that ever builds it and never builds it from a response body.
    /// The account is named by its one-character menu bar label and nothing
    /// else, exactly as in `line`.
    static func failureLine(
        label: Character, message: String, kind: Backoff.Failure, attempt: Int
    ) -> String {
        "usage [\(label)] failed verdict=\(message) ladder=\(kind) attempt=\(attempt)"
    }

    /// `name=absent` — never sent. `name=null/…` — sent, with no reading in it.
    /// `name=0/…` — sent, and the reading is zero. Those are three different
    /// facts and the whole point of the line is that they print differently.
    private static func field(_ name: String, _ bucket: UsageBucket?) -> String {
        guard let bucket else { return "\(name)=absent" }
        let reading = bucket.percent.map(number) ?? "null"
        return "\(name)=\(reading)/\(bucket.resetsAt == nil ? "no-window" : "window")"
    }

    private static func number(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

enum UsageError: LocalizedError {
    case unauthorized
    /// Carries the server's own `Retry-After` when it sent one, which outranks
    /// the locally computed backoff.
    case rateLimited(retryAfter: Date?)
    case http(Int)
    case badPayload

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "auth rejected"
        case .rateLimited: return "rate limited"
        case .http(let c): return "HTTP \(c)"
        case .badPayload: return "bad response"
        }
    }
}

// MARK: - Tolerant scalar helpers

enum JSONScalar {
    static func number(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}

/// `resets_at` arrives as ISO-8601 with six fractional digits and a `+00:00`
/// offset, which `ISO8601DateFormatter` does not reliably accept. Try the
/// strict form, then a 3-digit-fraction variant, then no fraction at all.
enum ISODate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let d = fractional.date(from: s) { return d }

        let parts = split(s)
        if let frac = parts.frac, !frac.isEmpty {
            let three = String((frac + "000").prefix(3))
            if let d = fractional.date(from: parts.base + "." + three + parts.tz) { return d }
        }
        if let d = plain.date(from: parts.base + parts.tz) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
                    "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                    "yyyy-MM-dd'T'HH:mm:ss"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    /// Splits `2026-08-12T01:40:00.087143+00:00` into base / fraction / zone.
    private static func split(_ s: String) -> (base: String, frac: String?, tz: String) {
        guard let tIdx = s.firstIndex(of: "T") else { return (s, nil, "") }
        if let dot = s[tIdx...].firstIndex(of: ".") {
            var i = s.index(after: dot)
            var frac = ""
            while i < s.endIndex, s[i].isNumber {
                frac.append(s[i])
                i = s.index(after: i)
            }
            return (String(s[s.startIndex..<dot]), frac, String(s[i...]))
        }
        var i = s.index(after: tIdx)
        while i < s.endIndex {
            let c = s[i]
            if c == "Z" || c == "+" || c == "-" {
                return (String(s[s.startIndex..<i]), nil, String(s[i...]))
            }
            i = s.index(after: i)
        }
        return (s, nil, "")
    }
}

// MARK: - Decoding

enum UsageDecoder {
    /// `limits[]` is the primary source; the flat keys are fallbacks only.
    /// Unknown keys are ignored on purpose — this payload's key set churns.
    static func decode(_ data: Data) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badPayload
        }
        var snap = UsageSnapshot()

        if let limits = root["limits"] as? [[String: Any]] {
            for entry in limits {
                let pct = JSONScalar.number(entry["percent"])
                let reset = ISODate.parse(entry["resets_at"] as? String)
                snap.limitKinds.append(entry["kind"] as? String ?? "?")
                switch entry["kind"] as? String {
                case "session":
                    snap.fiveHour = UsageBucket(id: "session", label: "5-hour", percent: pct, resetsAt: reset)
                case "weekly_all":
                    snap.weekly = UsageBucket(id: "weekly", label: "Weekly", percent: pct, resetsAt: reset)
                case "weekly_scoped":
                    let scope = entry["scope"] as? [String: Any]
                    let model = scope?["model"] as? [String: Any]
                    let name = (model?["display_name"] as? String) ?? "Weekly (scoped)"
                    snap.scoped.append(
                        UsageBucket(id: "scoped:\(name)", label: name, percent: pct, resetsAt: reset)
                    )
                default:
                    break
                }
            }
        }

        if snap.fiveHour == nil, let flat = root["five_hour"] as? [String: Any] {
            snap.usedFlatKeys = true
            snap.fiveHour = UsageBucket(
                id: "session", label: "5-hour",
                percent: JSONScalar.number(flat["utilization"]),
                resetsAt: ISODate.parse(flat["resets_at"] as? String)
            )
        }
        if snap.weekly == nil, let flat = root["seven_day"] as? [String: Any] {
            snap.usedFlatKeys = true
            snap.weekly = UsageBucket(
                id: "weekly", label: "Weekly",
                percent: JSONScalar.number(flat["utilization"]),
                resetsAt: ISODate.parse(flat["resets_at"] as? String)
            )
        }
        if snap.scoped.isEmpty {
            for (key, label) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
                guard let flat = root[key] as? [String: Any] else { continue }
                snap.usedFlatKeys = true
                let b = UsageBucket(
                    id: "scoped:\(label)", label: label,
                    percent: JSONScalar.number(flat["utilization"]),
                    resetsAt: ISODate.parse(flat["resets_at"] as? String)
                )
                if b.hasData { snap.scoped.append(b) }
            }
        }

        if snap.fiveHour == nil && snap.weekly == nil && snap.scoped.isEmpty {
            throw UsageError.badPayload
        }
        return snap
    }
}

// MARK: - Network

enum UsageClient {
    static func fetch(accessToken: String) async throws -> UsageSnapshot {
        var req = URLRequest(url: URL(string: Constants.usageURL)!)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(Constants.betaVersion, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await HTTP.data(for: req)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        switch code {
        case 200: return try UsageDecoder.decode(data)
        case 401, 403: throw UsageError.unauthorized
        case 429:
            throw UsageError.rateLimited(
                retryAfter: RetryAfter.parse(
                    http?.value(forHTTPHeaderField: "Retry-After")
                )
            )
        default: throw UsageError.http(code)
        }
    }
}
