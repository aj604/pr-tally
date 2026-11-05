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

    @Test func steadyDaysGiveATightRange() {
        let result = projection([10, 10, 10, 10], at: date(11, 4, hour: 12))!
        #expect(result.dailyDeviation == 0)
        #expect(result.low == result.expected)
        #expect(result.high == result.expected)
    }

    @Test func variableDaysGiveARangeAroundTheExpectedFinish() {
        let result = projection([30, 5, 16, 45], at: date(11, 4, hour: 20))!
        #expect(result.low < result.expected)
        #expect(result.expected < result.high)
    }

    @Test func theRangeNeverFallsBelowWhatIsAlreadyCounted() {
        let result = projection([60, 0, 0, 0, 0], at: date(11, 5, hour: 12))!
        #expect(result.low >= 60)
        #expect(result.band(at: 0.5).lowerBound >= 60)
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

    @Test func todaysPartialCountDoesNotWidenTheRange() {
        let early = projection([10, 10, 10, 0], at: date(11, 4, hour: 1))!
        let late = projection([10, 10, 10, 10], at: date(11, 4, hour: 22))!
        #expect(early.dailyDeviation == 0)
        #expect(late.dailyDeviation == 0)
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
}
