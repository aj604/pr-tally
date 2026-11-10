import Foundation

/// The days this month that beat the daily quota (goal ÷ days in the month), the bar today's count is held to in the
/// menu bar and the popover, so a day that beat it stays visible after midnight. Uses the current goal, not the goal
/// setting that may have been in effect on each day. A today that hasn't beaten the quota yet is still in progress,
/// so it isn't counted as a miss.
public struct MonthInsightQuotaDays: Sendable, Equatable {
    /// Count a steady pace adds each day. Matches `Pace.dailyQuota`.
    public let quota: Double
    /// Zero-based days of the month whose count went past `quota`, in order, today included once it has.
    public let beatenDays: [Int]
    /// Days judged so far: every completed day, plus today once it beats the quota.
    public let days: Int

    public var beaten: Int { beatenDays.count }

    /// Nil for a nonpositive goal, before the month, or while no day can be judged yet. After month end, judges every day.
    public init?(snapshot: MonthSnapshot, metric: PRMetric, goal: Int, at now: Date) {
        let window = snapshot.window
        guard goal > 0, now >= window.start else { return nil }
        let ended = now >= window.end
        let completed = ended ? window.dayCount : (window.dayIndex(of: now) ?? 0)
        let quota = Double(goal) / Double(window.dayCount)
        let daily = snapshot.dailyCounts(for: metric)
        // Same test as `Pace.beatsDailyQuota`: past the quota, not merely level with it.
        let beatenDays = daily.indices.prefix(ended ? completed : completed + 1).filter { Double(daily[$0]) > quota }
        let days = completed + (!ended && beatenDays.last == completed ? 1 : 0)
        guard days > 0 else { return nil }
        self.quota = quota
        self.beatenDays = beatenDays
        self.days = days
    }

    /// Whether the zero-based day beat the quota.
    public func beat(day: Int) -> Bool {
        beatenDays.contains(day)
    }
}
