import Foundation

/// Everything that decides *when* the app is allowed to talk to the usage
/// endpoint.
///
/// The endpoint is rate limited and this app is a passive observer, so the
/// budget is deliberately small: one request per account per `interval`, spaced
/// out rather than fired as a burst, and backed off hard the moment the server
/// pushes back.
enum PollPolicy {
    /// Base poll interval. A 5-hour window moves about 1% every three minutes,
    /// so anything faster than this buys no new information and only spends
    /// request budget.
    static let interval: TimeInterval = 300

    /// Gap between two accounts inside one pass, so N accounts never leave as
    /// N simultaneous requests.
    static let stagger: TimeInterval = 2

    /// How often the loop wakes to ask which accounts are due. Costs nothing on
    /// its own — no request is made unless an account's own schedule says so.
    static let tick: TimeInterval = 15

    /// Popover-open and wake-from-sleep are opportunistic: they only refetch
    /// when what is already on screen is older than this.
    static let freshness: TimeInterval = 60

    /// Manual refresh ignores `freshness`, but is still debounced this far
    /// apart, and never escapes backoff.
    static let manualDebounce: TimeInterval = 5
}

/// Per-account failure backoff. Kept pure and total so `--selftest` can walk
/// the entire schedule without a network.
enum Backoff {
    enum Failure: Equatable {
        /// HTTP 429. Starts at the base poll interval and doubles from there.
        case rateLimited
        /// 5xx, timeouts, offline, an unreadable payload. Cheaper to retry, so
        /// it starts far lower — but it still backs off, because a flapping
        /// connection would otherwise spin the loop.
        case transient

        var base: TimeInterval {
            switch self {
            case .rateLimited: return PollPolicy.interval
            case .transient: return 60
            }
        }

        var cap: TimeInterval {
            switch self {
            case .rateLimited: return 45 * 60
            case .transient: return 15 * 60
            }
        }
    }

    /// ±15%, so several accounts that failed together do not come back in
    /// lockstep and re-trip the limit as one burst.
    static let jitterFraction: Double = 0.15

    /// Un-jittered delay for the `failures`th consecutive failure, 1-based:
    /// 5m, 10m, 20m, 40m, then pinned at the 45m cap.
    static func delay(failures: Int, kind: Failure) -> TimeInterval {
        guard failures > 0 else { return 0 }
        // Clamp the exponent before it reaches `pow`, so a long outage cannot
        // run off to infinity on its way to being capped.
        let steps = Double(min(failures - 1, 16))
        return min(kind.cap, kind.base * pow(2, steps))
    }

    static func jittered(
        failures: Int,
        kind: Failure,
        roll: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) -> TimeInterval {
        let base = delay(failures: failures, kind: kind)
        guard base > 0 else { return 0 }
        let spread = base * jitterFraction
        return max(1, base + roll(-spread...spread))
    }

    /// When the next attempt may happen. A `Retry-After` the server actually
    /// sent outranks anything computed here — but it can only ever push the
    /// attempt further out, never pull it in front of the ordinary poll
    /// interval, so a `Retry-After: 1` cannot be used to hammer the endpoint.
    static func nextAttempt(
        failures: Int,
        kind: Failure,
        retryAfter: Date? = nil,
        now: Date = Date(),
        roll: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) -> Date {
        guard let retryAfter else {
            return now.addingTimeInterval(jittered(failures: failures, kind: kind, roll: roll))
        }
        return max(retryAfter, now.addingTimeInterval(PollPolicy.interval))
    }
}

/// One account's retry state, as a value type so `--selftest` can drive a whole
/// failure-and-recovery sequence deterministically.
struct RetrySchedule: Equatable {
    private(set) var failures = 0
    private(set) var blockedUntil: Date?

    var isBackedOff: Bool { failures > 0 }

    func isBlocked(at now: Date = Date()) -> Bool {
        guard let blockedUntil else { return false }
        return blockedUntil > now
    }

    /// The first success wipes the whole schedule — no decay, no half-memory.
    mutating func recordSuccess() {
        failures = 0
        blockedUntil = nil
    }

    mutating func recordFailure(
        _ kind: Backoff.Failure,
        retryAfter: Date? = nil,
        now: Date = Date(),
        roll: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        failures += 1
        blockedUntil = Backoff.nextAttempt(
            failures: failures, kind: kind, retryAfter: retryAfter, now: now, roll: roll
        )
    }
}

/// `Retry-After` is either a count of seconds or an HTTP-date. Servers send
/// both, so both are accepted; anything else is ignored in favour of the
/// computed backoff.
enum RetryAfter {
    private static let formatters: [DateFormatter] = {
        [
            "EEE, dd MMM yyyy HH:mm:ss zzz",   // RFC 1123, the one actually used
            "EEEE, dd-MMM-yy HH:mm:ss zzz",    // RFC 850
            "EEE MMM d HH:mm:ss yyyy"          // asctime
        ].map { pattern in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = pattern
            return formatter
        }
    }()

    static func parse(_ raw: String?, now: Date = Date()) -> Date? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }

        // A bare integer is by far the common case, and must be tried first:
        // "120" is a valid delay, not a date.
        if let seconds = Double(trimmed) {
            guard seconds.isFinite, seconds >= 0 else { return nil }
            return now.addingTimeInterval(seconds)
        }
        for formatter in formatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}

/// Why a refresh is being attempted. The only difference between them is how
/// stale the data on screen has to be before the request is worth making —
/// backoff applies to all three equally.
enum RefreshReason {
    /// The poll loop.
    case scheduled
    /// Popover opened, or the machine woke from sleep.
    case opportunistic
    /// The Refresh menu item.
    case manual

    /// How old the on-screen reading may be before this reason justifies a
    /// request. `nil` means "always, subject to backoff".
    var maxAge: TimeInterval? {
        switch self {
        case .scheduled: return PollPolicy.interval
        case .opportunistic: return PollPolicy.freshness
        case .manual: return nil
        }
    }
}
