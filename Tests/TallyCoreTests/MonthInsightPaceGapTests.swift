import Foundation
import Testing
@testable import TallyCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ day: Int, hour: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
}

private let window = MonthWindow(containing: date(1), calendar: calendar)

/// `perDay` PRs opened on each of days 1...`through`, read at noon on the day after.
private func gap(goal: Int, perDay: Int, through: Int, today: Int = 0) -> MonthInsightPaceGap? {
    let now = date(through + 1, hour: 12)
    let opened = (1...through).flatMap { day in
        (0..<perDay).map { index in
            PullRequest(
                id: "\(day)-\(index)", title: "A change", url: URL(string: "https://github.com/me/app/pull/1")!,
                createdAt: date(day, hour: 12), mergedAt: nil, repository: .init(nameWithOwner: "me/app")
            )
        }
    }
    let snapshot = MonthSnapshot(
        login: "me", window: window, opened: opened, merged: [], totalContributions: 0, fetchedAt: now
    )
    let pace = Pace(goal: goal, count: perDay * through + today, window: window, at: now)
    return MonthInsightPaceGap(
        pace: pace, today: today, activity: MonthInsightActivity(snapshot: snapshot, metric: .opened, at: now)
    )
}

@Suite struct MonthInsightPaceGapTests {
    @Test func theRecentRateIsTheAverageOverTheFullDays() throws {
        // Nov 11 at noon: days 4...10 are the seven full days before today, 4 PRs each.
        let gap = try #require(gap(goal: 1000, perDay: 4, through: 10))
        #expect(gap.days == 7)
        #expect(gap.recent == 4)
        // 40 counted, 960 left over 20 days.
        #expect(gap.needed == 48)
        #expect(gap.multiple == 12)
    }

    @Test func aRateAtOrAboveWhatIsNeededIsCovered() throws {
        // 100 counted of 140 leaves 40 over 20 days: 2 a day against 10.
        #expect(try #require(gap(goal: 140, perDay: 10, through: 10)).verdict == .covered)
        // Exactly the rate needed still counts as covered: 60 left over 20 days is 3, the rate.
        #expect(try #require(gap(goal: 120, perDay: 6, through: 10)).verdict == .covered)
    }

    @Test func upToHalfAgainTheRecentRateIsAStretch() throws {
        // 4 a day recent; 40 counted, goal 40 + 20 * 6 = 160 needs 6 a day: exactly 1.5x.
        #expect(try #require(gap(goal: 160, perDay: 4, through: 10)).verdict == .stretch)
    }

    @Test func pastHalfAgainIsASteepClimb() throws {
        // Goal 161 needs 6.05 a day against 4.
        #expect(try #require(gap(goal: 161, perDay: 4, through: 10)).verdict == .steepClimb)
    }

    @Test func nothingRecentMeansNoMultipleButStillASteepClimb() throws {
        let gap = try #require(gap(goal: 100, perDay: 0, through: 10))
        #expect(gap.recent == 0)
        #expect(gap.multiple == nil)
        #expect(gap.verdict == .steepClimb)
    }

    @Test func todaysCountDoesNotMoveTheNeededRateOrTheRecentOne() throws {
        let quiet = try #require(gap(goal: 1000, perDay: 4, through: 10))
        let busy = try #require(gap(goal: 1000, perDay: 4, through: 10, today: 30))
        #expect(quiet == busy)
    }

    @Test func fewerThanThreeFullDaysSaysNothing() {
        #expect(gap(goal: 1000, perDay: 4, through: 2) == nil)
        #expect(gap(goal: 1000, perDay: 4, through: 3) != nil)
    }

    @Test func aReachedGoalSaysNothing() {
        #expect(gap(goal: 40, perDay: 4, through: 10) == nil)
        #expect(gap(goal: 0, perDay: 4, through: 10) == nil)
    }

    @Test func aMonthWithNoDaysLeftSaysNothing() {
        let now = window.end.addingTimeInterval(3_600)
        let pace = Pace(goal: 1000, count: 10, window: window, at: now)
        #expect(pace.daysRemaining == 0)
        let snapshot = MonthSnapshot(
            login: "me", window: window, opened: [], merged: [], totalContributions: 0, fetchedAt: now
        )
        let activity = MonthInsightActivity(snapshot: snapshot, metric: .opened, at: now)
        #expect(MonthInsightPaceGap(pace: pace, today: 0, activity: activity) == nil)
    }
}
