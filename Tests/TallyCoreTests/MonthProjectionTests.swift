import Foundation
import Testing
@testable import TallyCore

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
    newYork.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

private let window = MonthWindow(containing: date(11, 1), calendar: newYork)

private func projection(_ daily: [Int], at now: Date) -> MonthProjection? {
    MonthProjection(count: daily.reduce(0, +), daily: daily + Array(repeating: 0, count: 30 - daily.count), window: window, at: now)
}

@Suite struct MonthProjectionTests {
    @Test func theExpectedFinishIsThePaceProjection() {
        let daily = [30, 5, 16, 45]
        let now = date(11, 4, hour: 20)
        let pace = Pace(goal: 1000, count: 96, window: window, at: now)
        #expect(projection(daily, at: now)?.expected == pace.projected)
    }

    @Test func identicalDaysStillLeaveARange() {
        let steady = projection([10, 10, 10, 5], at: date(11, 4, hour: 12))!
        #expect(steady.low < steady.expected)
        #expect(steady.expected < steady.high)
        let quiet = projection([0, 0, 0, 1], at: date(11, 4, hour: 12))!
        #expect(quiet.low < quiet.high)
        let none = projection([0, 0, 0, 0], at: date(11, 4, hour: 12))!
        #expect(none.low == 0)
        #expect(none.high > 0)
        #expect(none.high < 10)
    }

    @Test func fewerCompletedDaysUseAWiderTQuantile() {
        // Half-width is t * deviation * sqrt(left * (1 + left / elapsed)), with completed - 1 degrees of freedom.
        func half(_ result: MonthProjection, t: Double) -> Double {
            t * result.dailyDeviation * (result.daysLeft * (1 + result.daysLeft / result.daysElapsed)).squareRoot()
        }
        // A Sunday and two weekdays are too few to rate weekdays and weekends apart, so one rate gives the range.
        let three = projection([10, 30, 50, 0], at: date(11, 4, hour: 1))!
        #expect(three.split == nil)
        #expect(abs(three.band(at: 1).upperBound - Double(three.expected) - half(three, t: 1.886)) < 1e-9)
        // Rating two kinds of day costs a degree of freedom.
        #expect(projection([10, 30, 50, 30, 0], at: date(11, 5, hour: 1))?.split?.multiplier == 1.886)
        #expect(projection([10, 30, 50, 30, 20, 0], at: date(11, 6, hour: 1))?.split?.multiplier == 1.638)
    }

    @Test func quietWeekendsDoNotWidenTheRange() {
        // Six on each weekday and none at weekends, with half of Tuesday the 10th gone and 3 in so far. The weekdays
        // left (the rest of today and 14 more) put the finish at 39 + 6 * 14.5 = 126. One rate for every day read
        // the empty weekends as noise and gave 90–160.
        let result = projection([0, 6, 6, 6, 6, 6, 0, 0, 6, 3], at: date(11, 10, hour: 12))!
        #expect(result.split?.weekendRate == 0)
        #expect(result.low <= 126 && 126 <= result.high)
        #expect(result.high - result.low < 20)
        for step in 0...12 {
            let progress = Double(step) / 12
            #expect(result.band(at: progress).contains(39 + Double(result.expected - 39) * progress))
        }
    }

    @Test func beforeTheFirstWeekendTheRangeAllowsForAnEmptyOne() {
        // June 2026 starts on a Monday. Ten a day over its first five weekdays, at noon on the first Saturday: with
        // empty weekends it ends near 50 + 10 * 17 = 220, and with busy ones near the 273 one rate projects.
        let june = MonthWindow(containing: date(6, 1), calendar: newYork)
        let daily = [4, 16, 6, 14, 10] + Array(repeating: 0, count: 25)
        let result = MonthProjection(count: 50, daily: daily, window: june, at: date(6, 6, hour: 12))!
        #expect(result.split != nil)
        #expect(result.split?.weekendRate == nil)
        #expect(result.low <= 220)
        // The top is still the one rate's, spread and all: 4 degrees of freedom.
        #expect(result.expected == 273)
        let half = 1.533 * result.dailyDeviation * (result.daysLeft * (1 + result.daysLeft / result.daysElapsed)).squareRoot()
        #expect(abs(result.band(at: 1).upperBound - 273 - half) < 1e-9)
    }

    @Test func variableDaysGiveARangeAroundTheExpectedFinish() {
        let result = projection([30, 5, 16, 45], at: date(11, 4, hour: 20))!
        #expect(result.low < result.expected)
        #expect(result.expected < result.high)
    }

    @Test func theRangeNeverFallsBelowWhatIsAlreadyCounted() {
        let result = projection([60, 0, 0, 0, 0], at: date(11, 5, hour: 12))!
        #expect(result.low >= 60)
        #expect(result.band(at: 0.05).lowerBound == 60)
    }

    @Test func theRangeStartsAtTheCountAndWidensToMonthEnd() {
        let result = projection([30, 5, 16, 45], at: date(11, 4, hour: 20))!
        #expect(result.band(at: 0) == 96...96)
        let width = { (p: Double) in result.band(at: p).upperBound - result.band(at: p).lowerBound }
        #expect(width(0.25) < width(0.5))
        #expect(width(0.5) < width(1))
        #expect(result.band(at: 1).upperBound.rounded() == Double(result.high))
    }

    @Test func tooFewCompletedDaysGivesNoRange() {
        #expect(projection([30, 5], at: date(11, 3, hour: 12)) == nil)
        #expect(projection([30, 5, 16], at: date(11, 3, hour: 23)) == nil)
        #expect(projection([30, 5, 16], at: date(11, 4)) != nil)
    }

    @Test func todaysPartialCountDoesNotChangeTheSpreadOfCompletedDays() {
        let quiet = projection([10, 30, 50, 0], at: date(11, 4, hour: 1))!
        let busy = projection([10, 30, 50, 100], at: date(11, 4, hour: 1))!
        #expect(quiet.dailyDeviation == 20)
        #expect(busy.dailyDeviation == 20)
    }

    @Test func aRangeAboveTheCeilingStaysInsideThePlot() {
        // Steady 17 a day against a goal of 300 projects past 1.5 times the goal.
        let result = projection([17, 17, 17, 17, 17, 17, 17, 17, 17, 8], at: date(11, 10, hour: 12))!
        #expect(result.ceiling(goal: 300) == 450)
        #expect(result.low > 450)
        for step in 0...12 {
            let band = result.band(at: Double(step) / 12, within: 450)
            #expect(band.lowerBound <= band.upperBound)
            #expect(band.upperBound <= 450)
        }
    }

    @Test func aCountPastTheGoalSetsTheCeiling() {
        let result = projection([50, 50, 50, 50], at: date(11, 4, hour: 12))!
        #expect(result.count == 200)
        #expect(result.ceiling(goal: 100) == 200)
        for step in 0...12 {
            let band = result.band(at: Double(step) / 12, within: 200)
            #expect(band.lowerBound <= band.upperBound)
            #expect(band.upperBound <= 200)
        }
    }

    @Test func aRangeWithinTheCeilingIsDrawnAsIs() {
        let result = projection([30, 5, 16, 45], at: date(11, 4, hour: 20))!
        let ceiling = result.ceiling(goal: 1000)
        #expect(ceiling >= 1000)
        #expect(result.band(at: 0.5, within: ceiling) == result.band(at: 0.5))
        #expect(result.band(at: 1, within: ceiling) == result.band(at: 1))
    }

    @Test func noRangeOnceTheMonthIsOver() {
        #expect(projection([10, 10, 10, 10], at: date(12, 1)) == nil)
    }

    @Test func theSnapshotProjectsTheSelectedMetric() {
        func pr(_ id: String, created: Date, merged: Date? = nil) -> PullRequest {
            PullRequest(
                id: id, title: "A change", url: URL(string: "https://github.com/a/b/pull/1")!,
                createdAt: created, mergedAt: merged, repository: .init(nameWithOwner: "a/b"))
        }
        let opened = (0..<12).map { pr("o\($0)", created: date(11, 1 + $0 / 3, hour: 9)) }
        let merged = [pr("m0", created: date(10, 20), merged: date(11, 2))]
        let snapshot = MonthSnapshot(
            login: "someone", window: window, opened: opened, merged: merged, totalContributions: 0, fetchedAt: date(11, 5))
        let now = date(11, 5, hour: 12)
        #expect(snapshot.projection(for: .opened, at: now)?.count == 12)
        #expect(snapshot.projection(for: .merged, at: now)?.count == 1)
    }

    /// Steady days at 10 a day should finish inside the range about 80% of the time, early and late.
    @Test func steadyMonthsFinishInsideTheRangeAboutEightyPercentOfTheTime() {
        var random = SplitMix64(seed: 42)
        let trials = 1500
        for completed in [3, 10, 20] {
            var inside = 0
            for _ in 0..<trials {
                let days = (0..<30).map { _ in random.poisson(10) }
                // Noon on the next day, with half of that day's PRs in.
                var daily = Array(days.prefix(completed)) + [random.binomial(days[completed], 0.5)]
                daily += Array(repeating: 0, count: 30 - daily.count)
                let now = date(11, completed + 1, hour: 12)
                let result = MonthProjection(count: daily.reduce(0, +), daily: daily, window: window, at: now)!
                if result.low <= days.reduce(0, +), days.reduce(0, +) <= result.high { inside += 1 }
            }
            let coverage = Double(inside) / Double(trials)
            #expect(abs(coverage - 0.8) < 0.05, "coverage after \(completed) days was \(coverage)")
        }
    }

    /// With ten a weekday and one a weekend day, one rate for every day landed inside 43% of the time four days into
    /// a month starting on a Monday, and 99% of the time with a range twice as wide by day 10 of November.
    @Test func monthsWithQuietWeekendsFinishInsideTheRangeAboutEightyPercentOfTheTime() {
        var random = SplitMix64(seed: 7)
        let trials = 1500
        for (month, completed, expected) in [(6, 4, 0.8...0.97), (11, 10, 0.75...0.9), (11, 20, 0.75...0.9)] {
            let window = MonthWindow(containing: date(month, 1), calendar: newYork)
            let weekend = (0..<window.dayCount).map { newYork.isDateInWeekend(date(month, $0 + 1, hour: 12)) }
            var inside = 0
            for _ in 0..<trials {
                let days = weekend.map { random.poisson($0 ? 1 : 10) }
                var daily = Array(days.prefix(completed)) + [random.binomial(days[completed], 0.5)]
                daily += Array(repeating: 0, count: window.dayCount - daily.count)
                let now = date(month, completed + 1, hour: 12)
                let result = MonthProjection(count: daily.reduce(0, +), daily: daily, window: window, at: now)!
                if result.low <= days.reduce(0, +), days.reduce(0, +) <= result.high { inside += 1 }
            }
            let coverage = Double(inside) / Double(trials)
            #expect(expected.contains(coverage), "coverage after \(completed) days of month \(month) was \(coverage)")
        }
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func poisson(_ mean: Double) -> Int {
        let limit = exp(-mean)
        var product = uniform()
        var count = 0
        while product > limit {
            count += 1
            product *= uniform()
        }
        return count
    }

    mutating func binomial(_ trials: Int, _ chance: Double) -> Int {
        (0..<trials).filter { _ in uniform() < chance }.count
    }
}
