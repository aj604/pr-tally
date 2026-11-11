import Foundation

/// Where the month is likely to end, as a range rather than the single number `Pace.projected` gives.
/// Early in a month a few days of counts say little, and days vary a lot, so one figure overstates what is known.
/// The range allows for the days still to come and for how roughly the rate so far is known, treating days as
/// independent draws, so it doesn't know about a streak. It does know about weekends: weekdays and weekends are rated
/// apart (see `WeekdaySplit`). In simulated months the real finish landed inside it about 80% of the time for steady
/// days from day 3 to day 20, nearer 90% before the first weekend of a month starting Monday to Wednesday. For lumpy
/// days (a few big ones among quiet ones, or mostly empty ones) that is only about half the time at day 3, 60% at
/// day 5 and 75% to 80% from day 10. With quiet weekends it is 75% to 87% from day 4 whatever weekday the month starts
/// on, and over 90% before the first weekend. One rate for every day managed 45% in the first week of a month starting
/// on a Monday, and well over 90% for most other starts with a range twice as wide. It is also wider than needed in
/// the last days of the month.
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
    /// Day-to-day spread assumed for a day's count: that of the completed days, but no less than a tenth of that of a
    /// Poisson count at the rate so far, so a run of identical days (or a lone PR) doesn't read as certainty.
    /// It only guards that degenerate case: a larger floor pushes steady days well over 80%.
    public let dailyDeviation: Double
    /// Time passed in the month in days, counting the part of today so far.
    public let daysElapsed: Double
    /// Time left in the month in days, counting the rest of today.
    public let daysLeft: Double
    private let multiplier: Double
    /// The range with weekdays and weekends rated apart, nil when the completed days are too few to.
    let split: WeekdaySplit?

    /// Nil when too few days have completed to tell how much they vary, or when the month is over.
    public init?(count: Int, daily: [Int], window: MonthWindow, at now: Date) {
        let completed = window.dayIndex(of: now) ?? 0
        guard completed >= Self.minimumCompletedDays, daily.count >= completed else { return nil }
        let elapsed = window.elapsedFraction(at: now)
        guard elapsed < 1 else { return nil }
        let days = daily.prefix(completed).map(Double.init)
        let mean = days.reduce(0, +) / Double(completed)
        let variance = days.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(completed - 1)
        let daysElapsed = Double(window.dayCount) * elapsed
        let floor = 0.1 * (Double(max(count, 1)) / daysElapsed).squareRoot()
        self.count = count
        self.expected = Pace.projectedTotal(count: count, window: window, at: now)
        self.daysElapsed = daysElapsed
        self.dailyDeviation = max(variance.squareRoot(), floor)
        self.daysLeft = Double(window.dayCount) * (1 - elapsed)
        self.multiplier = Self.tQuantile(degreesOfFreedom: completed - 1)
        self.split = WeekdaySplit(daily: daily, completed: completed, window: window, daysLeft: daysLeft, floor: floor)
    }

    static func tQuantile(degreesOfFreedom: Int) -> Double {
        tQuantiles[min(degreesOfFreedom - 2, tQuantiles.count - 1)]
    }

    /// The range of the total once `progress` of the time left has passed, from 0 (now) to 1 (month end).
    /// It never dips below what is already counted, and always contains the line to `expected`, so it never
    /// disagrees with "On track for". Its half-width adds the variation of the days still to come to the error in
    /// the rate the centre is extended at, which shrinks as more of the month is seen.
    public func band(at progress: Double) -> ClosedRange<Double> {
        let progress = min(max(progress, 0), 1)
        let center = Double(count) + Double(expected - count) * progress
        let ahead = daysLeft * progress
        let half = multiplier * dailyDeviation * (ahead * (1 + ahead / daysElapsed)).squareRoot()
        let oneRate = (center - half)...(center + half)
        guard let split else { return max(oneRate.lowerBound, Double(count))...oneRate.upperBound }
        let apart = split.band(count: count, ahead: ahead)
        // Before the first weekend it may be as busy as the weekdays or empty, so the range spans both. After it, the
        // split range is the better guide, stretched only as far as the line one rate draws.
        let outer = split.weekendRate == nil ? oneRate : center...center
        return max(min(outer.lowerBound, apart.lowerBound), Double(count))...max(outer.upperBound, apart.upperBound)
    }

    /// Highest total a plot needs room for: the goal, what is counted, and the range up to 1.5 times the goal.
    /// A lumpy early month can project many times the goal, and making room for all of it would flatten the plot.
    public func ceiling(goal: Int) -> Int {
        max(goal, count, min(Int(band(at: 1).upperBound.rounded(.up)), goal * 3 / 2))
    }

    /// `band(at:)` held inside a plot that reaches `ceiling`. A range that starts above it becomes a flat line
    /// along the top, not an inverted one.
    public func band(at progress: Double, within ceiling: Int) -> ClosedRange<Double> {
        let band = band(at: progress)
        let top = Double(ceiling)
        return min(band.lowerBound, top)...min(band.upperBound, top)
    }

    /// Lower end of the likely month-end count.
    public var low: Int { Int(band(at: 1).lowerBound.rounded()) }
    /// Upper end of the likely month-end count.
    public var high: Int { Int(band(at: 1).upperBound.rounded()) }
}

extension MonthProjection {
    /// The month's rate on weekdays and on weekends apart, for the many people whose weekends are quiet. One rate
    /// for every day carries the first five weekdays straight across the weekends ahead, and reads quiet weekends
    /// already seen as day-to-day noise, which widens the range for the rest of the month.
    struct WeekdaySplit: Sendable, Equatable {
        let weekdayRate: Double
        /// Nil until a weekend day has completed.
        let weekendRate: Double?
        let weekdays: Int
        let weekendDays: Int
        /// Spread of a day around its own kind's rate, pooled across both, with the same floor as `dailyDeviation`.
        let deviation: Double
        let multiplier: Double
        /// Whether each day from today to the month's end is a weekend day.
        let weekendAhead: [Bool]
        /// The part of today still to come, in days.
        let todayLeft: Double

        /// Nil without a completed weekday, or with too few completed days to estimate a spread around two rates.
        init?(daily: [Int], completed: Int, window: MonthWindow, daysLeft: Double, floor: Double) {
            let calendar = window.calendar
            let isWeekend = (0..<window.dayCount).map { day in
                calendar.date(byAdding: .day, value: day, to: window.start).map(calendar.isDateInWeekend) ?? false
            }
            let weekdays = (0..<completed).filter { !isWeekend[$0] }.map { Double(daily[$0]) }
            let weekendDays = (0..<completed).filter { isWeekend[$0] }.map { Double(daily[$0]) }
            let kinds = [weekdays, weekendDays].filter { !$0.isEmpty }
            let degreesOfFreedom = completed - kinds.count
            guard !weekdays.isEmpty, degreesOfFreedom >= 2 else { return nil }
            let mean = { (days: [Double]) in days.reduce(0, +) / Double(days.count) }
            let squares = kinds.map { days in
                let center = mean(days)
                return days.map { ($0 - center) * ($0 - center) }.reduce(0, +)
            }
            self.weekdayRate = mean(weekdays)
            self.weekendRate = weekendDays.isEmpty ? nil : mean(weekendDays)
            self.weekdays = weekdays.count
            self.weekendDays = weekendDays.count
            self.deviation = max((squares.reduce(0, +) / Double(degreesOfFreedom)).squareRoot(), floor)
            self.multiplier = MonthProjection.tQuantile(degreesOfFreedom: degreesOfFreedom)
            self.weekendAhead = Array(isWeekend[completed...])
            // A day an hour short or long for daylight saving can leave this a sliver below zero.
            self.todayLeft = max(daysLeft - Double(window.dayCount - completed - 1), 0)
        }

        /// The range once `ahead` more days have passed. A weekend not yet seen counts as empty here; the range
        /// one rate gives covers it being as busy as the weekdays.
        func band(count: Int, ahead: Double) -> ClosedRange<Double> {
            var weekdaysAhead = 0.0
            var weekendAhead = 0.0
            var left = ahead
            for (day, weekend) in self.weekendAhead.enumerated() where left > 0 {
                let part = min(left, day == 0 ? todayLeft : 1)
                if weekend { weekendAhead += part } else { weekdaysAhead += part }
                left -= part
            }
            let center = Double(count) + weekdayRate * weekdaysAhead + (weekendRate ?? 0) * weekendAhead
            // Each rate's error shrinks with the days of its kind seen so far.
            let rateError = weekdaysAhead * weekdaysAhead / Double(weekdays)
                + (weekendDays > 0 ? weekendAhead * weekendAhead / Double(weekendDays) : 0)
            let half = multiplier * deviation * (ahead + rateError).squareRoot()
            return max(center - half, Double(count))...(center + half)
        }
    }
}

extension MonthSnapshot {
    public func projection(for metric: PRMetric, at now: Date) -> MonthProjection? {
        MonthProjection(count: count(for: metric), daily: dailyCounts(for: metric), window: window, at: now)
    }
}
