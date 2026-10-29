import Foundation

/// A persisted throttle for automatic basic HealthKit refreshes. Manual reads do not use it.
struct CoveHealthRefreshPolicy: Codable, Equatable {
    static let metricIDs: Set<String> = [
        "sleep", "sleepAwake", "sleepCore", "sleepDeep", "sleepREM", "sleepUnspecified",
        "restingHeartRate", "hrv", "steps", "oxygenSaturation"
    ]

    private static let minimumInterval: TimeInterval = 6 * 60 * 60
    private static let dailyLimit = 2

    private(set) var dayKey: Int?
    private(set) var attemptsToday: Int
    private(set) var lastAttemptAt: Date?

    init(dayKey: Int? = nil, attemptsToday: Int = 0, lastAttemptAt: Date? = nil) {
        self.dayKey = dayKey
        self.attemptsToday = attemptsToday
        self.lastAttemptAt = lastAttemptAt
    }

    /// The first attempt of a Beijing calendar day is unconditional. A second requires
    /// a HealthKit change notification; both count even if the eventual read fails.
    func eligibility(now: Date, changed: Bool) -> Bool {
        guard now.timeIntervalSince1970.isFinite else { return false }
        let today = Self.beijingDayKey(for: now)
        if let dayKey, today < dayKey { return false }
        if let lastAttemptAt {
            let elapsed = now.timeIntervalSince(lastAttemptAt)
            guard elapsed.isFinite, elapsed >= Self.minimumInterval else { return false }
        }
        let attempts = dayKey == today ? attemptsToday : 0
        guard attempts >= 0, attempts < Self.dailyLimit else { return false }
        return attempts == 0 || changed
    }

    /// Persist the returned state before starting an automatic read. `nil` means no attempt
    /// should be made, and leaves the existing budget unchanged.
    func recordingAttempt(now: Date, changed: Bool) -> Self? {
        guard eligibility(now: now, changed: changed) else { return nil }
        let today = Self.beijingDayKey(for: now)
        return Self(dayKey: today,
                    attemptsToday: (dayKey == today ? attemptsToday : 0) + 1,
                    lastAttemptAt: now)
    }

    private static func beijingDayKey(for date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return parts.year! * 10_000 + parts.month! * 100 + parts.day!
    }
}
