import Foundation

// MARK: - Model

struct UsageBucket: Identifiable, Hashable {
    let id: String
    let label: String
    let percent: Double
    let resetsAt: Date?
    /// `percent == 0 && resetsAt == nil` is the API's "no data" sentinel.
    let hasData: Bool

    init(id: String, label: String, percent: Double?, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.percent = percent ?? 0
        self.resetsAt = resetsAt
        self.hasData = !((percent ?? 0) == 0 && resetsAt == nil)
    }
}

struct UsageSnapshot {
    var fiveHour: UsageBucket?
    var weekly: UsageBucket?
    /// Every `weekly_scoped` bucket found, in API order.
    var scoped: [UsageBucket] = []
    var fetchedAt: Date = Date()

    func scoped(named name: String) -> UsageBucket? {
        scoped.first { $0.label.caseInsensitiveCompare(name) == .orderedSame }
    }

    var fable: UsageBucket? { scoped(named: "Fable") }

    /// The single number the menu bar draws: how much room is left before the
    /// tightest of the three windows blocks you. A bucket the API did not report
    /// is not a constraint, so it is skipped rather than counted as 0 or 100.
    /// `nil` means nothing resolved at all — an unknown state, not "full".
    var headroom: Double? {
        let remaining = [fiveHour, weekly, fable]
            .compactMap { $0 }
            .filter(\.hasData)
            .map { 100 - $0.percent }
        guard let tightest = remaining.min() else { return nil }
        return max(0, min(100, tightest))
    }
}

enum UsageError: LocalizedError {
    case unauthorized
    case rateLimited
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
            snap.fiveHour = UsageBucket(
                id: "session", label: "5-hour",
                percent: JSONScalar.number(flat["utilization"]),
                resetsAt: ISODate.parse(flat["resets_at"] as? String)
            )
        }
        if snap.weekly == nil, let flat = root["seven_day"] as? [String: Any] {
            snap.weekly = UsageBucket(
                id: "weekly", label: "Weekly",
                percent: JSONScalar.number(flat["utilization"]),
                resetsAt: ISODate.parse(flat["resets_at"] as? String)
            )
        }
        if snap.scoped.isEmpty {
            for (key, label) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
                guard let flat = root[key] as? [String: Any] else { continue }
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

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return try UsageDecoder.decode(data)
        case 401, 403: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited
        default: throw UsageError.http(code)
        }
    }
}
