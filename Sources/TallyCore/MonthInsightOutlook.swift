import Foundation

/// Where the goal sits against the likely finish range, so "117–227" reads as an answer about the goal.
/// Only meaningful while the goal is still open: once the count has reached it, there is no outlook to give.
public enum MonthInsightOutlook: Sendable, Equatable {
    /// The goal is at or below the low end, so the current rate reaches it even on a weak stretch.
    case likelyToReach
    /// The goal falls inside the range: the rest of the month decides it.
    case withinRange
    /// The goal is above the high end, so only a big change of pace reaches it.
    case outOfReach

    /// Nil for a goal already reached, or a nonpositive one.
    public init?(projection: MonthProjection, goal: Int) {
        guard goal > 0, projection.count < goal else { return nil }
        if goal <= projection.low {
            self = .likelyToReach
        } else if goal > projection.high {
            self = .outOfReach
        } else {
            self = .withinRange
        }
    }
}
