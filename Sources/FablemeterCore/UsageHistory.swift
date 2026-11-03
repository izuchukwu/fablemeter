import Foundation

struct UsageSample: Codable, Equatable {
    let accountID: UUID
    let date: Date
    let percent: Double
}

enum HistoryWindow: String, CaseIterable {
    case fiveHours = "5h", day = "24h", week = "7d"
    var duration: TimeInterval {
        switch self {
        case .fiveHours: return 5 * 3600
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        }
    }
}

struct UsageHistory {
    static let retention: TimeInterval = 7 * 24 * 3600
    let file: URL
    var samples: [UsageSample]

    init(file: URL = Store.directory.appendingPathComponent("usage-history.json"), now: Date = Date()) {
        self.file = file
        let data = try? Data(contentsOf: file)
        samples = data.flatMap { try? JSONDecoder().decode([UsageSample].self, from: $0) } ?? []
        prune(now: now)
    }

    mutating func prune(now: Date) {
        samples.removeAll { $0.date < now.addingTimeInterval(-Self.retention) || $0.date > now }
    }

    mutating func record(_ sample: UsageSample, now: Date = Date()) throws {
        prune(now: now)
        if sample.date >= now.addingTimeInterval(-Self.retention), sample.date <= now,
           sample.percent.isFinite {
            samples.append(sample)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(try JSONEncoder().encode(samples), to: file, mode: 0o600)
    }

    func slice(accountID: UUID, window: HistoryWindow, now: Date) -> [UsageSample] {
        samples.filter { $0.accountID == accountID && $0.date >= now.addingTimeInterval(-window.duration) && $0.date <= now }
            .sorted { $0.date < $1.date }
    }
}
