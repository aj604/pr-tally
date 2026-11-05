import Foundation

/// Where the month is likely to end, as a range rather than the single number `Pace.projected` gives.
/// Early in a month a few days of counts say little, and days vary a lot, so one figure overstates what is known.
/// The range allows for the days still to come and for how roughly the rate so far is known, treating days as
/// independent draws, so it doesn't know about weekends or a streak. In simulated months the real finish landed
/// inside it about 80% of the time for steady days from day 3 to day 20. For lumpy days (a few big ones among quiet
/// ones, or mostly empty ones) that is only about half the time at day 3, 60% at day 5 and 75% to 80% from day 10.
/// It is wider than needed when weekends are quiet, and in the last days of the month.
public struct MonthProjection: Sendable, Equatable {
    /// Completed days needed before a spread means anything.
    public static let minimumCompletedDays = 3
    /// Student's t quantile for a two-sided 80% range, by degrees of freedom from 2. A sample of a few days is a
    /// poor guide to the spread, so the range is wider the fewer days there are. Beyond the table it approaches 1.28.
    private static let tQuantiles: [Double] = [
        1.886, 1.638, 1.533, 1.476, 1.440, 1.415, 1.397, 1.383, 1.372, 1.363, 1.356, 1.350, 1.345, 1.341, 1.337,
        1.333, 1.330, 1.328, 1.325, 1.323, 1.321, 1.319, 1.318, 1.316, 1.315, 1.314, 1.313, 1.311, 1.310,
    ]

    public let count: Int
    /// Month-end count if the rate so far continues. Always equals `Pace.projected`.
    public let expected: Int
    /// Day-to-day spread assumed for a day's count: that of the completed days, but no less than half that of a
    /// Poisson count at the rate so far, so a run of identical days (or a lone PR) doesn't read as certainty.
    /// Half, because the full Poisson spread makes the range too wide for steady days.
    public let dailyDeviation: Double
    /// Time passed in the month in days, counting the part of today so far.
    public let daysElapsed: Double
    /// Time left in the month in days, counting the rest of today.
    public let daysLeft: Double
    private let multiplier: Double

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
        self.daysElapsed = Double(window.dayCount) * elapsed
        self.dailyDeviation = max(variance.squareRoot(), 0.5 * (Double(max(count, 1)) / daysElapsed).squareRoot())
        self.daysLeft = Double(window.dayCount) * (1 - elapsed)
        self.multiplier = Self.tQuantiles[min(completed - 2, Self.tQuantiles.count - 1)]
    }

    /// The range of the total once `progress` of the time left has passed, from 0 (now) to 1 (month end).
    /// It never dips below what is already counted. Its half-width adds the variation of the days still to come
    /// to the error in the rate the centre is extended at, which shrinks as more of the month is seen.
    public func band(at progress: Double) -> ClosedRange<Double> {
        let progress = min(max(progress, 0), 1)
        let center = Double(count) + Double(expected - count) * progress
        let ahead = daysLeft * progress
        let half = multiplier * dailyDeviation * (ahead * (1 + ahead / daysElapsed)).squareRoot()
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
