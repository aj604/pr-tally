import Foundation

/// Where the month is likely to end, as a range rather than the single number `Pace.projected` gives.
/// Early in a month a few days of counts say little, and days vary a lot, so one figure overstates what is known.
/// The range treats each remaining day as an independent draw like the completed ones, so it doesn't know
/// about weekends or a streak, and is a rough guide rather than a forecast.
public struct MonthProjection: Sendable, Equatable {
    /// Completed days needed before a spread means anything.
    public static let minimumCompletedDays = 3
    /// Standard deviations either side that the range covers: about 80% of outcomes if days were independent.
    private static let deviations = 1.28

    public let count: Int
    /// Month-end count if the rate so far continues. Always equals `Pace.projected`.
    public let expected: Int
    /// Standard deviation of the daily counts on the days already completed.
    public let dailyDeviation: Double
    /// Time left in the month in days, counting the rest of today.
    public let daysLeft: Double

    /// Nil when too few days have completed to tell how much they vary, or when the month is over.
    public init?(count: Int, daily: [Int], window: MonthWindow, at now: Date) {
        let completed = window.dayIndex(of: now) ?? 0
        guard completed >= Self.minimumCompletedDays, daily.count >= completed else { return nil }
        let elapsed = window.elapsedFraction(at: now)
        guard elapsed < 1 else { return nil }
        let days = daily.prefix(completed).map(Double.init)
        let mean = days.reduce(0, +) / Double(completed)
        let variance = days.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(completed - 1)
        self.count = count
        self.expected = Pace.projectedTotal(count: count, window: window, at: now)
        self.dailyDeviation = variance.squareRoot()
        self.daysLeft = Double(window.dayCount) * (1 - elapsed)
    }

    /// The range of the total once `progress` of the time left has passed, from 0 (now) to 1 (month end).
    /// It widens with the square root of the time, and never dips below what is already counted.
    public func band(at progress: Double) -> ClosedRange<Double> {
        let progress = min(max(progress, 0), 1)
        let center = Double(count) + Double(expected - count) * progress
        let half = Self.deviations * dailyDeviation * (daysLeft * progress).squareRoot()
        return max(center - half, Double(count))...(center + half)
    }

    /// Lower end of the likely month-end count.
    public var low: Int { Int(band(at: 1).lowerBound.rounded()) }
    /// Upper end of the likely month-end count.
    public var high: Int { Int(band(at: 1).upperBound.rounded()) }
}

extension MonthSnapshot {
    public func projection(for metric: PRMetric, at now: Date) -> MonthProjection? {
        MonthProjection(count: count(for: metric), daily: dailyCounts(for: metric), window: window, at: now)
    }
}
