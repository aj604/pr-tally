import Foundation

/// What the goal asks of each remaining day set beside what the last full days actually delivered, so
/// "Needed / day 41.7" reads against a rate the person recognises. Uses completed days only (`MonthInsightActivity`),
/// so a quiet morning can't look like a slowdown, and needs a few of them before an average means anything.
public struct MonthInsightPaceGap: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// The recent rate already meets what each remaining day needs.
        case covered
        /// Needs up to half again the recent rate: a push, not a different month.
        case stretch
        /// Needs well over half again the recent rate.
        case steepClimb
    }

    /// Completed days needed before their average is quoted. Matches `MonthProjection.minimumCompletedDays`.
    public static let minimumDays = MonthProjection.minimumCompletedDays
    /// Where a push becomes a different month: the needed rate over this multiple of the recent one.
    public static let stretchLimit = 1.5

    /// Count needed per remaining day, from the start of today.
    public let needed: Double
    /// Count per day over the recent full days.
    public let recent: Double
    /// How many full days `recent` averages.
    public let days: Int

    /// `needed` over `recent`, or nil when nothing has been counted recently to divide by.
    public var multiple: Double? { recent > 0 ? needed / recent : nil }

    public var verdict: Verdict {
        if needed <= recent { return .covered }
        guard let multiple, multiple <= Self.stretchLimit else { return .steepClimb }
        return .stretch
    }

    /// Nil once the goal is reached or the month is over (nothing is needed), a nonpositive goal, or while fewer than
    /// `minimumDays` full days exist.
    public init?(pace: Pace, today: Int, activity: MonthInsightActivity?) {
        guard pace.goal > 0, pace.remaining > 0, pace.daysRemaining > 0,
            let activity, activity.recentDays.count >= Self.minimumDays
        else { return nil }
        needed = pace.neededPerDay(today: today)
        days = activity.recentDays.count
        recent = Double(activity.recentCount) / Double(days)
    }
}
