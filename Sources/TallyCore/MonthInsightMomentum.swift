import Foundation

/// Where the recent days disagree with the whole month about the goal. The chart's likely finish extends the rate of
/// the entire month, and `MonthInsightPaceGap` looks only at the last full days, so after an uneven month they can
/// point opposite ways ("goal in reach" beside "needs 1.8× the recent pace"). Naming the disagreement lets the popover
/// say which one to believe for today instead of leaving two verdicts side by side.
public enum MonthInsightMomentum: Sendable, Equatable {
    /// The month's rate reaches the goal, but the recent days run slower and would not.
    case slowing
    /// The month's rate falls short, but the recent days already run fast enough to reach it.
    case catchingUp

    /// Nil when the two agree, or when either has nothing to say (goal reached, month over, too few days).
    /// A goal inside the range (`withinRange`) is left alone: the range already says the month could go either way.
    public init?(outlook: MonthInsightOutlook?, gap: MonthInsightPaceGap?) {
        switch (outlook, gap?.verdict) {
        case (.likelyToReach?, .stretch?), (.likelyToReach?, .steepClimb?):
            self = .slowing
        case (.outOfReach?, .covered?):
            self = .catchingUp
        default:
            return nil
        }
    }
}
