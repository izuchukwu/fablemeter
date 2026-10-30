import Foundation
@testable import FablemeterCore

/// A local, display-only reading. It never enters account or switching state.
struct CodexReading {
    let weekly: UsageBucket
    var fiveHour: UsageBucket? = nil
    let resetCredits: Int?

    var verdict: String {
        guard let percent = weekly.percent else { return "No data" }
        if percent >= 95 { return "Ask for reset" }
        if percent >= 90 { return "Warning" }
        return "Available"
    }

    static func decode(_ data: Data) -> CodexReading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rail = root["rail"] as? String,
              let snapshot = root["snapshot"] as? [String: Any] else { return nil }
        let isHTTP = rail == "http"
        guard isHTTP || rail == "app-server" else { return nil }
        let limits = snapshot[isHTTP ? "rate_limit" : "rateLimits"] as? [String: Any] ?? [:]
        let candidates = isHTTP ? ["primary_window", "secondary_window"] : ["primary", "secondary"]
        func bucket(seconds: Double, id: String, label: String) -> UsageBucket? {
            for key in candidates {
                guard let window = limits[key] as? [String: Any],
                      let duration = JSONScalar.number(window[isHTTP ? "limit_window_seconds" : "windowDurationMins"]),
                      duration == (isHTTP ? seconds : seconds / 60),
                      let percent = JSONScalar.number(window[isHTTP ? "used_percent" : "usedPercent"]),
                      percent.isFinite, (0...100).contains(percent) else { continue }
                let epoch = JSONScalar.number(window[isHTTP ? "reset_at" : "resetsAt"])
                return UsageBucket(id: id, label: label, percent: percent,
                    resetsAt: epoch.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
            }
            return nil
        }
        guard let weekly = bucket(seconds: 604800, id: "codex-weekly", label: "Weekly") else { return nil }
        let credits = snapshot[isHTTP ? "rate_limit_reset_credits" : "rateLimitResetCredits"] as? [String: Any]
        let count = JSONScalar.number(credits?[isHTTP ? "available_count" : "availableCount"])
        return CodexReading(weekly: weekly,
            fiveHour: bucket(seconds: 18000, id: "codex-five-hour", label: "5-hour"),
            resetCredits: count.flatMap { $0.isFinite && $0 >= 0 && $0 < 1_000_000 && $0.rounded() == $0 ? Int($0) : nil })
    }

    static func fetch() -> CodexReading? {
        let process = Process()
        process.executableURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/bin/codex-quota")
        process.arguments = ["--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return decode(data)
        } catch { return nil }
    }
}
