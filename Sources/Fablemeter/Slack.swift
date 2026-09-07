import Foundation
import os

// MARK: - Slack mirror

/// Where a warning goes besides the notification center. Read once from
/// `slack.json` beside `accounts.json`, same 0700 directory and same 0600 file
/// mode as the account store, because the bot token in it is a credential.
///
/// Absent is the normal case, not an error: a machine that has never been given
/// a token simply does not mirror. So every failure here is silent to the user
/// and says its piece once, in the log, exactly like a denied notification.
struct SlackConfig: Decodable, Equatable {
    let token: String
    let channel: String

    /// Both fields must be non-empty for a post to be possible, so a file with
    /// a blank one is treated as no file at all rather than as a configuration
    /// that fails on every warning.
    static func decode(_ data: Data) -> SlackConfig? {
        guard let config = try? JSONDecoder().decode(SlackConfig.self, from: data),
              !config.token.isEmpty, !config.channel.isEmpty
        else { return nil }
        return config
    }
}

enum Slack {
    static var file: URL { Store.directory.appendingPathComponent("slack.json") }

    /// Slack reads `text` as mrkdwn, and its own escaping rules are these three
    /// characters and no others: everything else, `*` and `_` and backticks
    /// included, is formatting the message is entitled to carry. Pure so
    /// `--selftest` can pin it.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The same title and body the macOS notification carries, one above the
    /// other.
    static func message(title: String, body: String) -> String {
        escape(title) + "\n" + escape(body)
    }

    /// Re-read per post rather than cached: dropping a token in while the app
    /// runs should start the mirror, and taking it away should stop it, with no
    /// relaunch either way. The file is tiny and a warning is rare.
    static func config() -> SlackConfig? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return SlackConfig.decode(data)
    }

    /// Post, and never throw: a warning that reached the notification center
    /// must not be undone by a network that did not answer. Returns whether
    /// Slack accepted it, which is what `--slack-test` reports and what the
    /// warning path ignores.
    @discardableResult
    static func post(title: String, body: String) async -> Bool {
        guard let config = config() else {
            noteMissingConfigOnce()
            return false
        }
        return await post(message(title: title, body: body), with: config)
    }

    static func post(_ text: String, with config: SlackConfig) async -> Bool {
        var request = URLRequest(url: URL(string: "https://slack.com/api/chat.postMessage")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["channel": config.channel, "text": text]
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let json, json["ok"] as? Bool == true { return true }
            // Slack's `error` is a fixed vocabulary of slugs, so it is safe to
            // log; the body it came in is not, and never goes near this line.
            let slug = (json?["error"] as? String) ?? "no ok field"
            Log.usage.notice("slack: post refused, HTTP \(status, privacy: .public) \(slug, privacy: .public)")
            return false
        } catch {
            // The URL error code, not the message: a message can name the host,
            // the proxy, or the request.
            let code = (error as? URLError)?.code.rawValue ?? -1
            Log.usage.notice("slack: post failed, URLError \(code, privacy: .public)")
            return false
        }
    }

    /// Said once per launch. A machine with no token would otherwise write this
    /// line on every warning forever, which is how a normal condition turns
    /// into noise.
    private static let missingLogged = OSAllocatedUnfairLock(initialState: false)

    private static func noteMissingConfigOnce() {
        let first = missingLogged.withLock { logged -> Bool in
            defer { logged = true }
            return !logged
        }
        if first { Log.usage.notice("slack: no slack.json, staying quiet") }
    }
}

// MARK: - --slack-test

/// Posts one line and says whether Slack took it, so the wiring can be proved
/// without waiting for a real threshold to be crossed.
enum SlackTest {
    static func run() async -> Int32 {
        guard let config = Slack.config() else {
            print("slack-test: no readable \(Slack.file.path)")
            return 1
        }
        print("slack-test: config loaded, channel \(config.channel) (token not shown)")
        let sent = await Slack.post("fablemeter: Slack test", with: config)
        print(sent ? "slack-test: posted" : "slack-test: refused, see the log for the reason")
        return sent ? 0 : 1
    }
}
