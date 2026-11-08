import Foundation

/// The busiest local calendar day so far, choosing the most recent when counts tie.
public struct MonthInsightBestDay: Sendable, Equatable {
    /// Zero-based day of the month, suitable for the chart's day selection.
    public let day: Int
    public let count: Int
    public let tiedDays: Int

    /// Nil before the month or without activity through today. After month end, includes the whole month.
    public init?(snapshot: MonthSnapshot, metric: PRMetric, at now: Date) {
        let window = snapshot.window
        guard now >= window.start else { return nil }
        let days = now >= window.end ? window.dayCount : (window.dayIndex(of: now) ?? 0) + 1
        let daily = snapshot.dailyCounts(for: metric).prefix(days)
        guard let count = daily.max(), count > 0,
            let day = daily.lastIndex(of: count)
        else { return nil }
        self.day = day
        self.count = count
        tiedDays = daily.filter { $0 == count }.count
    }
}
