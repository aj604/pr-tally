import Foundation

/// The first local calendar day whose running total reached the current monthly goal.
public struct MonthInsightGoalDay: Sendable, Equatable {
    /// Zero-based day of the month, suitable for the chart's day selection.
    public let day: Int

    /// Uses the current goal, not the goal setting that may have been in effect on that day.
    /// Nil for nonpositive or unreached goals. Future calendar days are excluded; ended months include all days.
    public init?(snapshot: MonthSnapshot, metric: PRMetric, goal: Int, at now: Date) {
        guard goal > 0,
            let day = snapshot.cumulativeCounts(for: metric, through: now).firstIndex(where: { $0 >= goal })
        else { return nil }
        self.day = day
    }
}
