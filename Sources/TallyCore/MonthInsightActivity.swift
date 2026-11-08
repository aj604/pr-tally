import Foundation

/// Recent activity within one month, using full calendar days so today's partial count cannot look like a slowdown.
public struct MonthInsightActivity: Sendable, Equatable {
    /// Zero-based days of the month, at most seven, ending just before today.
    public let recentDays: Range<Int>
    public let recentCount: Int
    /// A comparison is available only when both periods contain seven completed days in this month.
    public let previousDays: Range<Int>?
    public let previousCount: Int?

    public var change: Int? { previousCount.map { recentCount - $0 } }

    /// Nil until the month has a completed day. After month end, uses its final seven days.
    public init?(snapshot: MonthSnapshot, metric: PRMetric, at now: Date) {
        let window = snapshot.window
        let completed = now >= window.end ? window.dayCount : (window.dayIndex(of: now) ?? 0)
        guard completed > 0 else { return nil }
        let daily = snapshot.dailyCounts(for: metric)
        recentDays = max(0, completed - 7)..<completed
        recentCount = daily[recentDays].reduce(0, +)
        previousDays = completed >= 14 ? (completed - 14)..<(completed - 7) : nil
        previousCount = previousDays.map { daily[$0].reduce(0, +) }
    }
}
