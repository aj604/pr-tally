import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ day: Int, hour: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
}

/// Days 4...10 hold `perDay` PRs each, read at noon on the 11th, against `goal`.
private func text(goal: Int, perDay: Int) -> MonthInsightPaceGapText {
    let window = MonthWindow(containing: date(1), calendar: calendar)
    let now = date(11, hour: 12)
    let opened = (1...10).flatMap { day in
        (0..<perDay).map { index in
            PullRequest(
                id: "\(day)-\(index)", title: "A change", url: URL(string: "https://github.com/me/app/pull/1")!,
                createdAt: date(day, hour: 12), mergedAt: nil, repository: .init(nameWithOwner: "me/app")
            )
        }
    }
    let snapshot = MonthSnapshot(login: "me", window: window, opened: opened, merged: [], totalContributions: 0, fetchedAt: now)
    let pace = Pace(goal: goal, count: perDay * 10, window: window, at: now)
    let gap = MonthInsightPaceGap(
        pace: pace, today: 0, activity: MonthInsightActivity(snapshot: snapshot, metric: .opened, at: now)
    )!
    return MonthInsightPaceGapText(gap: gap)
}

@Suite struct MonthInsightPaceGapTextTests {
    @Test func aSteepClimbStatesTheRateAndTheMultiple() {
        // 4 a day recent against 48 needed.
        let text = text(goal: 1000, perDay: 4)
        #expect(text.line == "Recent pace 4.0 a day · needs 12× that")
        #expect(text.help.contains("48.0 a day"))
    }

    @Test func aStretchKeepsOneDecimalOnTheMultiple() {
        #expect(text(goal: 160, perDay: 4).line == "Recent pace 4.0 a day · needs 1.5× that")
    }

    @Test func aCoveredGoalNamesWhatIsNeeded() {
        #expect(text(goal: 140, perDay: 10).line == "Recent pace 10.0 a day · enough for the 2.0 needed")
    }

    @Test func nothingRecentSaysNoMultiple() {
        #expect(text(goal: 100, perDay: 0).line == "Recent pace 0.0 a day")
    }

    @Test func theChartIsSpokenWithItsVerdict() {
        let window = MonthWindow(containing: date(1), calendar: calendar)
        let projection = MonthProjection(
            count: 100, daily: Array(repeating: 10, count: 10) + Array(repeating: 0, count: 20), window: window, at: date(11, hour: 12)
        )!
        let spoken = MonthInsightOutlookText(projection: projection, goal: 1000).spoken
        #expect(spoken == "Likely finish \(projection.low) to \(projection.high), short of the goal")
        #expect(MonthInsightOutlookText(projection: projection, goal: 100).spoken == "Likely finish \(projection.low) to \(projection.high)")
    }
}

/// With a recent pace of 10 a day, a goal of `100 + 200 * multiple` needs `multiple` times that over the 20 days left.
@Suite struct MonthInsightPaceGapMultipleRoundingTests {
    @Test func aStretchJustAboveTheRecentRateIsNotRoundedDownToOne() {
        // 1.04x: nearest would print "1.0×", which reads as covered.
        #expect(text(goal: 308, perDay: 10).line == "Recent pace 10.0 a day · needs 1.1× that")
    }

    @Test func aSteepClimbJustAboveTheStretchLimitIsNotRoundedDownToIt() {
        // 1.52x: nearest would print "1.5×", the text a stretch at exactly the limit gets.
        #expect(text(goal: 404, perDay: 10).line == "Recent pace 10.0 a day · needs 1.6× that")
    }

    @Test func aMultipleThatRoundsUpToTenUsesTheWholeNumberFormat() {
        // 9.96x: nearest would print "10.0×".
        #expect(text(goal: 2092, perDay: 10).line == "Recent pace 10.0 a day · needs 10× that")
    }

    @Test func aMultipleThatIsExactlyOneDecimalIsNotBumpedUp() {
        // 4.2 needed over 3 recent is 1.4000000000000001, which would round up to 1.5.
        #expect(text(goal: 114, perDay: 3).line == "Recent pace 3.0 a day · needs 1.4× that")
    }
}
