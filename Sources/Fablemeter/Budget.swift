import Foundation
@testable import FablemeterCore

/// One account's self-imposed 5-hour budget (Izu, 2026-10-31): at most
/// `capPercent` of the weekly allowance per 5-hour window. The window logic,
/// the caps and the swap behavior all live in the `fablemeter` CLI, which the
/// cascade and the guard already run; the app only reads its view and asks it
/// to reset, so there is one implementation of the rule, not two.
struct BudgetEntry: Equatable {
    let label: String
    let capPercent: Double
    /// Weekly percentage points spent in this window. `nil` when the CLI had
    /// no live reading to measure against.
    let usedPercent: Double?
    let capped: Bool
    let active: Bool
    let windowEnd: Date?

    /// The meter's fill: the share of the cap spent, 0...100.
    var fractionOfCap: Double {
        guard let usedPercent, capPercent > 0 else { return 0 }
        return min(100, max(0, usedPercent / capPercent * 100))
    }

    /// Percentage of the self-imposed cap spent; may exceed 100%.
    var text: String {
        guard let usedPercent, capPercent > 0 else { return "—" }
        return "\(Int((usedPercent / capPercent * 100).rounded()))%"
    }

}

enum Budget {
    static var tool: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/bin/fablemeter")
    }

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: tool.path) }

    /// The interpreter is named rather than left to the shebang: a login item
    /// starts with launchd's bare PATH, where `env python3` may not resolve.
    static var python: String {
        // Apple silicon Homebrew, Intel Homebrew, then the system stub.
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }

    static func decode(_ data: Data) -> [String: BudgetEntry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["accounts"] as? [String: [String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        var out: [String: BudgetEntry] = [:]
        for (label, row) in accounts {
            guard let cap = JSONScalar.number(row["capPercent"]) else { continue }
            out[label.uppercased()] = BudgetEntry(
                label: label.uppercased(),
                capPercent: cap,
                usedPercent: JSONScalar.number(row["usedPercent"]),
                capped: row["capped"] as? Bool == true,
                active: row["active"] as? Bool == true,
                windowEnd: (row["windowEnd"] as? String).flatMap { iso.date(from: $0) }
            )
        }
        return out
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [tool.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch { return nil }
    }

    /// Ticks the windows (the CLI persists them) and returns the view.
    static func fetch() -> [String: BudgetEntry]? {
        run(["budget", "--json"]).flatMap(decode)
    }

    /// Starts a fresh window now: for one account, or for all of them.
    static func reset(label: String?) -> Bool {
        run(["reset-window"] + (label.map { [$0] } ?? [])) != nil
    }
}
