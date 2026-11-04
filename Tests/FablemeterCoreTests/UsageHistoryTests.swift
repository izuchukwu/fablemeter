import XCTest
@testable import FablemeterCore

final class UsageHistoryTests: XCTestCase {
    func testPersistencePruningAndSlicing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let now = Date(timeIntervalSince1970: 2_000_000)
        let account = UUID(), other = UUID()
        var history = UsageHistory(file: file, now: now)
        for (id, age, value) in [(account, 3600.0, 10.0), (account, 12 * 3600.0, 20.0), (account, 6 * 86400.0, 30.0), (account, 8 * 86400.0, 40.0), (other, 3600.0, 50.0)] {
            try history.record(UsageSample(accountID: id, date: now.addingTimeInterval(-age), percent: value), now: now)
        }
        let loaded = UsageHistory(file: file, now: now)
        XCTAssertEqual(loaded.samples.count, 4)
        XCTAssertEqual(loaded.slice(accountID: account, window: .fiveHours, now: now).map(\.percent), [10])
        XCTAssertEqual(loaded.slice(accountID: account, window: .day, now: now).map(\.percent), [20, 10])
        XCTAssertEqual(loaded.slice(accountID: account, window: .week, now: now).map(\.percent), [30, 20, 10])
        var later = loaded
        later.prune(now: now.addingTimeInterval(7 * 86400 + 1))
        XCTAssertTrue(later.samples.isEmpty)
    }
    func testRecordsAvailableMetricsForClaudeAndCodex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let now = Date(), claude = UUID()
        var history = UsageHistory(file: file, now: now)
        try history.record(accountID: claude, date: now, fiveHour: nil, weekly: 0, now: now)
        try history.record(accountID: UsageHistory.codexID, date: now, fiveHour: 20, weekly: 40, now: now)
        let loaded = UsageHistory(file: file, now: now)
        for window in HistoryWindow.allCases {
            XCTAssertEqual(loaded.slice(accountID: claude, window: window, now: now, metric: .weekly).map(\.percent), [0])
            XCTAssertTrue(loaded.slice(accountID: claude, window: window, now: now).isEmpty)
            XCTAssertEqual(loaded.slice(accountID: UsageHistory.codexID, window: window, now: now, metric: .fiveHour).map(\.percent), [20])
            XCTAssertEqual(loaded.slice(accountID: UsageHistory.codexID, window: window, now: now, metric: .weekly).map(\.percent), [40])
        }
    }

    func testLegacySamplesDecodeAsFiveHour() throws {
        let id = UUID(), date = Date(timeIntervalSinceReferenceDate: 100)
        let json = "[{\"accountID\":\"\(id)\",\"date\":100,\"percent\":12}]".data(using: .utf8)!
        let samples = try JSONDecoder().decode([UsageSample].self, from: json)
        XCTAssertEqual(samples, [UsageSample(accountID: id, date: date, percent: 12)])
    }
}
