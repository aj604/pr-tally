import Foundation

/// Consecutive local days with activity in one month. A quiet today doesn't end yesterday's run yet.
public struct MonthInsightStreak: Sendable, Equatable {
    public let currentDays: Int
    public let bestDays: Int

    /// Nil before the month or until it has activity. At month end, the current run ends on its final day.
    public init?(snapshot: MonthSnapshot, metric: PRMetric, at now: Date) {
        let window = snapshot.window
        guard now >= window.start else { return nil }
        let daily = snapshot.dailyCounts(for: metric)
        let ended = now >= window.end
        let last = ended ? window.dayCount - 1 : (window.dayIndex(of: now) ?? 0)
        var run = 0
        var best = 0
        for count in daily.prefix(last + 1) {
            run = count > 0 ? run + 1 : 0
            best = max(best, run)
        }
        guard best > 0 else { return nil }
        // Today is still in progress; only a completed quiet day breaks a streak.
        if !ended, daily[last] == 0, last > 0 {
            run = 0
            for count in daily.prefix(last).reversed() {
                guard count > 0 else { break }
                run += 1
            }
        }
        currentDays = run
        bestDays = best
    }
}
