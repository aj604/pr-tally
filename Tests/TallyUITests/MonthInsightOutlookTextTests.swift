import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private let window = MonthWindow(containing: newYork.date(from: DateComponents(year: 2026, month: 11, day: 1))!, calendar: newYork)
private let now = newYork.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!

/// Ten completed days of ten PRs: a finish of about 300, with a range around it.
private let projection = MonthProjection(
    count: 100, daily: Array(repeating: 10, count: 10) + Array(repeating: 0, count: 20), window: window, at: now
)!

@Suite struct MonthInsightOutlookTextTests {
    @Test func aGoalAboveTheRangeSaysTheMonthFallsShort() {
        let text = MonthInsightOutlookText(projection: projection, goal: 1000)
        #expect(text.line == "Likely finish: \(projection.low)–\(projection.high) · short of the goal")
        #expect(text.help.contains("1,000"))
    }

    @Test func aGoalInsideTheRangeSaysItIsStillOpen() {
        let text = MonthInsightOutlookText(projection: projection, goal: projection.expected)
        #expect(text.line.hasSuffix("· goal still open"))
    }

    @Test func aGoalBelowTheRangeSaysItIsInReach() {
        let text = MonthInsightOutlookText(projection: projection, goal: 150)
        #expect(text.line.hasSuffix("· goal in reach"))
    }

    @Test func aReachedGoalKeepsTheBareRange() {
        let text = MonthInsightOutlookText(projection: projection, goal: 100)
        #expect(text.line == "Likely finish: \(projection.low)–\(projection.high)")
    }
}
