import Foundation
@testable import FablemeterCore
import UserNotifications

// MARK: - Delivery

/// The one impure edge: hands warnings to the notification center and owns the
/// fired-key set. Authorization is asked for the first time a warning actually
/// wants to fire — an app that asks for notification rights at launch is
/// asking before it has anything to say.
@MainActor
final class Warner {
    private(set) var fired = Set<String>()
    /// The last day's warnings with when they fired, for the push payload, so
    /// a follower can show the fresh ones itself. Additive: nothing here
    /// changes what this machine notifies or posts.
    let ledger = WarningLedger()
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
        ledger.record(warnings)

        // Slack is a second destination, not a fallback, so it runs before the
        // notification guard and independently of it: a run that cannot notify
        // — denied rights, or an unbundled `swift run` — still mirrors. The
        // dedup above is what keeps it to one post per warning.
        let mirrored = warnings
        Task.detached {
            for warning in mirrored {
                await Slack.post(title: warning.title, body: warning.body)
            }
        }

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
