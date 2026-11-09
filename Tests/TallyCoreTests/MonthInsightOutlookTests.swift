import Foundation
import Testing
@testable import TallyCore

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private let window = MonthWindow(containing: newYork.date(from: DateComponents(year: 2026, month: 11, day: 1))!, calendar: newYork)
private let now = newYork.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!

/// Ten completed days of `perDay`, then nothing yet today.
private func projection(perDay: Int, in days: Int = 10) -> MonthProjection {
    let daily = Array(repeating: perDay, count: days) + Array(repeating: 0, count: 30 - days)
    return MonthProjection(count: perDay * days, daily: daily, window: window, at: now)!
}

@Suite struct MonthInsightOutlookTests {
    @Test func aGoalBelowTheRangeIsLikelyToBeReached() {
        let steady = projection(perDay: 10)
        #expect(MonthInsightOutlook(projection: steady, goal: steady.low) == .likelyToReach)
        #expect(MonthInsightOutlook(projection: steady, goal: 100) == .likelyToReach)
    }

    @Test func aGoalInsideTheRangeStaysOpen() {
        let steady = projection(perDay: 10)
        #expect(MonthInsightOutlook(projection: steady, goal: steady.low + 1) == .withinRange)
        #expect(MonthInsightOutlook(projection: steady, goal: steady.expected) == .withinRange)
        #expect(MonthInsightOutlook(projection: steady, goal: steady.high) == .withinRange)
    }

    @Test func aGoalAboveTheRangeIsOutOfReach() {
        let steady = projection(perDay: 10)
        #expect(MonthInsightOutlook(projection: steady, goal: steady.high + 1) == .outOfReach)
        #expect(MonthInsightOutlook(projection: steady, goal: 1000) == .outOfReach)
    }

    @Test func aReachedOrNonpositiveGoalHasNoOutlook() {
        let steady = projection(perDay: 10)
        #expect(MonthInsightOutlook(projection: steady, goal: steady.count) == nil)
        #expect(MonthInsightOutlook(projection: steady, goal: 50) == nil)
        #expect(MonthInsightOutlook(projection: steady, goal: 0) == nil)
        #expect(MonthInsightOutlook(projection: steady, goal: -5) == nil)
    }
}
