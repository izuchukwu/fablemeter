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
}
