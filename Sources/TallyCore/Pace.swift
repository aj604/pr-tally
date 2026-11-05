import Foundation

/// Where a count stands against a monthly goal at a moment in time.
public struct Pace: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case goalHit, ahead, onPace, behind
    }

    public let goal: Int
    public let count: Int
    /// Count a steady pace would have reached by now.
    public let expected: Int
    /// Month-end count if the rate so far continues.
    public let projected: Int
    public let remaining: Int
    public let daysRemaining: Int
    /// Count needed per day, including today, to reach the goal.
    public let neededPerDay: Double
    /// Count a steady pace adds each day. Fixed for the month, unlike `neededPerDay`.
    public let dailyQuota: Double

    public init(goal: Int, count: Int, window: MonthWindow, at now: Date) {
        let elapsed = window.elapsedFraction(at: now)
        // A floor of one day keeps the first hours of a month from projecting absurd totals.
        let oneDay = 1 / Double(window.dayCount)
        self.goal = goal
        self.count = count
        self.expected = Int((Double(goal) * elapsed).rounded())
        self.projected = Int((Double(count) / max(elapsed, oneDay)).rounded())
        self.remaining = max(goal - count, 0)
        self.daysRemaining = window.daysRemaining(at: now)
        self.neededPerDay = daysRemaining > 0 ? Double(remaining) / Double(daysRemaining) : 0
        self.dailyQuota = Double(goal) / Double(window.dayCount)
    }

    /// Whole PRs past the daily quota today, or 0 if not past it. Once the goal is hit there's no quota left to beat.
    public func quotaSurplus(today: Int) -> Int {
        guard status != .goalHit else { return 0 }
        return max(Int((Double(today) - dailyQuota).rounded(.up)), 0)
    }

    /// Whether today's count went past the daily quota. Unlike `quotaSurplus`, this holds after the goal is hit.
    public func beatsDailyQuota(today: Int) -> Bool {
        Double(today) > dailyQuota
    }

    /// Positive when ahead of a steady pace, negative when behind.
    public var delta: Int { count - expected }

    public var status: Status {
        if count >= goal { return .goalHit }
        if delta > 0 { return .ahead }
        if delta < 0 { return .behind }
        return .onPace
    }

    /// Progress toward the goal, capped at 1.
    public var fraction: Double {
        goal > 0 ? min(Double(count) / Double(goal), 1) : 0
    }
}
