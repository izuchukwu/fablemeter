import Foundation
import UserNotifications

// MARK: - Warnings

/// One warning, as pure data. The policy below produces these and the
/// `Warner` at the edge turns them into notifications, so every rule about
/// *when* to warn can be proved by `--selftest` without a notification center
/// or a clock.
struct UsageWarning: Equatable {
    let title: String
    let body: String
    /// Dedup identity: account + bucket + rule + the window it fired in
    /// (keyed on `resetsAt`). A new window is a new key, which is what
    /// re-arms the warning after a reset.
    let key: String
}

/// Which warnings the user has left on. All on by default — the reason this
/// feature exists is a 5-hour window that went from 0 to 100 in half an hour
/// with nothing said.
struct WarnSettings {
    var at75 = true
    var at90 = true
    var at95 = true
    var fastBurn = true

    var enabledThresholds: [Double] {
        [(75.0, at75), (90.0, at90), (95.0, at95)]
            .filter(\.1).map(\.0)
    }
}

enum WarnPolicy {
    /// The 5-hour window, which is what "elapsed fraction" is measured against.
    static let fiveHourWindow: TimeInterval = 5 * 3600

    /// Fast-burn checkpoints: warn when usage crosses `percent` while less than
    /// `maxElapsed` of the 5-hour window has passed. Izu's own numbers, flagged
    /// by him as guesses ("not sure what way too fast is exactly") — retune
    /// here and the selftest's expectations when he does.
    static let fastBurnCheckpoints: [(percent: Double, maxElapsed: Double)] = [
        (20, 0.2),
        (50, 0.5),
    ]

    /// Everything the policy decides, in one pure call: compare the reading
    /// that just arrived against the last one that ever did, and say what to
    /// warn about. `fired` is the set of keys already warned; a key in it is
    /// skipped, which is the once-per-window rule.
    ///
    /// The null rule holds throughout: a bucket whose new reading is null
    /// produces nothing, counts as nothing, and a baseline that was never a
    /// real reading is no baseline at all — never zero. A failure between two
    /// polls does not break the chain, because `AccountState` keeps the last
    /// snapshot that arrived, so `previous` here is always the last *real*
    /// reading even when the poll in between died.
    static func assess(
        label: Character,
        previous: UsageSnapshot?,
        current: UsageSnapshot,
        now: Date,
        settings: WarnSettings,
        fired: Set<String>
    ) -> [UsageWarning] {
        var warnings: [UsageWarning] = []

        let pairs: [(name: String, prev: UsageBucket?, cur: UsageBucket?)] = [
            ("5-hour", previous?.fiveHour, current.fiveHour),
            ("Weekly", previous?.weekly, current.weekly),
            ("Fable", previous?.fable, current.fable),
        ]

        for pair in pairs {
            guard let bucket = pair.cur, let reading = bucket.percent else { continue }
            guard let baseline = pair.prev?.percent else { continue }

            // One warning per poll per bucket: a jump that clears several
            // thresholds at once names only the highest, because three
            // notifications about one number is noise wearing a safety vest.
            if let crossed = settings.enabledThresholds
                .filter({ baseline < $0 && reading >= $0 })
                .max() {
                let warning = UsageWarning(
                    title: "\(label) — \(pair.name) at \(Int(reading.rounded()))%",
                    body: "Resets \(Format.resetStamp(bucket.resetsAt, from: now))",
                    key: key(label, pair.name, "t\(Int(crossed))", bucket.resetsAt)
                )
                if !fired.contains(warning.key) { warnings.append(warning) }
            }

            // Fast burn is a 5-hour question only: the weekly windows are long
            // enough that their thresholds already tell the story.
            guard pair.name == "5-hour", settings.fastBurn,
                  let elapsed = elapsedFraction(resetsAt: bucket.resetsAt, now: now)
            else { continue }
            for checkpoint in fastBurnCheckpoints
            where baseline < checkpoint.percent
                && reading >= checkpoint.percent
                && elapsed < checkpoint.maxElapsed {
                let warning = UsageWarning(
                    title: "\(label) — fast burn",
                    body: "\(Int(checkpoint.percent))% of the 5-hour window in "
                        + duration(elapsed * fiveHourWindow),
                    key: key(label, pair.name, "burn\(Int(checkpoint.percent))", bucket.resetsAt)
                )
                if !fired.contains(warning.key) { warnings.append(warning) }
            }
        }
        return warnings
    }

    /// How much of the 5-hour window has passed, from its reset stamp. `nil`
    /// when there is no stamp or the stamp is not a plausible 5-hour window —
    /// no reading of time, no fast-burn verdict, same rule as every other null.
    static func elapsedFraction(resetsAt: Date?, now: Date) -> Double? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= fiveHourWindow else { return nil }
        return (fiveHourWindow - remaining) / fiveHourWindow
    }

    private static func key(
        _ label: Character, _ bucket: String, _ rule: String, _ resetsAt: Date?
    ) -> String {
        let window = resetsAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "none"
        return "\(label):\(bucket):\(rule):\(window)"
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }
}

// MARK: - Delivery

/// The one impure edge: hands warnings to the notification center and owns the
/// fired-key set. Authorization is asked for the first time a warning actually
/// wants to fire — an app that asks for notification rights at launch is
/// asking before it has anything to say.
@MainActor
final class Warner {
    private(set) var fired = Set<String>()
    private var denied = false
    private var deniedLogged = false

    /// `UNUserNotificationCenter` traps outside a real bundle, so a bare
    /// `swift run` process must never touch it. Same boundary as `LoginItem`.
    private let isBundled = Bundle.main.bundlePath.hasSuffix(".app")

    func deliver(_ warnings: [UsageWarning]) {
        guard !warnings.isEmpty else { return }
        // Marked fired even when delivery is impossible: the decision to warn
        // was made once, and a denied notification must not come back as a
        // fresh warning every poll.
        fired.formUnion(warnings.map(\.key))
        guard isBundled, !denied else { return }

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else {
                self.denied = true
                if !self.deniedLogged {
                    self.deniedLogged = true
                    Log.usage.notice("warn: notifications denied, staying quiet")
                }
                return
            }
            for warning in warnings {
                let content = UNMutableNotificationContent()
                content.title = warning.title
                content.body = warning.body
                try? await center.add(UNNotificationRequest(
                    identifier: warning.key, content: content, trigger: nil
                ))
            }
        }
    }
}
