import Foundation

enum HistoryMetric: String, Codable { case fiveHour, weekly }

struct UsageSample: Codable, Equatable {
    let accountID: UUID
    let date: Date
    let percent: Double
    var metric: HistoryMetric = .fiveHour

    enum CodingKeys: String, CodingKey { case accountID, date, percent, metric }
    init(accountID: UUID, date: Date, percent: Double, metric: HistoryMetric = .fiveHour) {
        self.accountID = accountID; self.date = date; self.percent = percent; self.metric = metric
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.decode(UUID.self, forKey: .accountID)
        date = try c.decode(Date.self, forKey: .date)
        percent = try c.decode(Double.self, forKey: .percent)
        metric = try c.decodeIfPresent(HistoryMetric.self, forKey: .metric) ?? .fiveHour
    }
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
    static let codexID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let retention: TimeInterval = 7 * 24 * 3600
    let file: URL
    var samples: [UsageSample]

    init(file: URL = LocalState.directory.appendingPathComponent("usage-history.json"), now: Date = Date()) {
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

    mutating func record(accountID: UUID, date: Date, fiveHour: Double?, weekly: Double?, now: Date = Date()) throws {
        for (metric, value) in [(HistoryMetric.fiveHour, fiveHour), (.weekly, weekly)] {
            if let value, value.isFinite {
                try record(UsageSample(accountID: accountID, date: date, percent: value, metric: metric), now: now)
            }
        }
    }

    func slice(accountID: UUID, window: HistoryWindow, now: Date, metric: HistoryMetric = .fiveHour) -> [UsageSample] {
        samples.filter { $0.accountID == accountID && $0.metric == metric && $0.date >= now.addingTimeInterval(-window.duration) && $0.date <= now }
            .sorted { $0.date < $1.date }
    }
}
