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

private func snapshot(opened: [Int] = [], merged: [Int] = []) -> MonthSnapshot {
    func prs(_ days: [Int], merged: Bool) -> [PullRequest] {
        days.enumerated().map { index, day in
            PullRequest(
                id: "\(merged)-\(index)", title: "Fixture", url: URL(string: "https://example.test/\(index)")!,
                createdAt: merged ? date(0) : date(day), mergedAt: merged ? date(day) : nil,
                repository: .init(nameWithOwner: "me/app")
            )
        }
    }
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: date(1), calendar: calendar),
        opened: prs(opened, merged: false), merged: prs(merged, merged: true), totalContributions: 0, fetchedAt: date(30)
    )
}

@Suite struct MonthInsightGoalDayTests {
    @Test func picksTheFirstCrossingEvenAfterFurtherActivityAndQuietDays() {
        let fixture = snapshot(opened: [8, 3, 1, 3, 12])
        #expect(MonthInsightGoalDay(snapshot: fixture, metric: .opened, goal: 3, at: date(20))?.day == 2)
    }

    @Test func aDayCanOvershootTheGoalWithoutAnExactMatch() {
        let fixture = snapshot(opened: [1, 3, 3, 3, 8])
        #expect(MonthInsightGoalDay(snapshot: fixture, metric: .opened, goal: 3, at: date(10))?.day == 2)
    }

    @Test func changedGoalsRecomputeTheirOwnCrossingDay() {
        let fixture = snapshot(opened: [1, 3, 3, 8, 8])
        #expect(MonthInsightGoalDay(snapshot: fixture, metric: .opened, goal: 1, at: date(10))?.day == 0)
        #expect(MonthInsightGoalDay(snapshot: fixture, metric: .opened, goal: 4, at: date(10))?.day == 7)
        #expect(MonthInsightGoalDay(snapshot: fixture, metric: .opened, goal: 6, at: date(10)) == nil)
    }

    @Test func openedAndMergedUseTheirOwnEventDates() {
        let fixture = snapshot(opened: [1, 2], merged: [5, 6])
        #expect(MonthInsightGoalDay(snapshot: fixture, metric: .opened, goal: 2, at: date(10))?.day == 1)
        #expect(MonthInsightGoalDay(snapshot: fixture, metric: .merged, goal: 2, at: date(10))?.day == 5)
    }

    @Test func todayCanReachTheGoalButFutureDaysCannot() {
        let fixture = snapshot(opened: [1, 2, 3])
        #expect(MonthInsightGoalDay(snapshot: fixture, metric: .opened, goal: 2, at: date(2, hour: 12))?.day == 1)
        #expect(MonthInsightGoalDay(snapshot: fixture, metric: .opened, goal: 3, at: date(2, hour: 12)) == nil)
    }

    @Test func invalidGoalsAndEmptyOrNotYetStartedMonthsHaveNoDate() {
        #expect(MonthInsightGoalDay(snapshot: snapshot(), metric: .opened, goal: 1, at: date(15)) == nil)
        let fixture = snapshot(opened: [1])
        for goal in [0, -1] {
            #expect(MonthInsightGoalDay(snapshot: fixture, metric: .opened, goal: goal, at: date(15)) == nil)
        }
        #expect(MonthInsightGoalDay(snapshot: fixture, metric: .opened, goal: 1, at: date(0)) == nil)
    }

    @Test func monthEndIncludesTheLastDayAndExcludesAdjacentMonths() {
        let fixture = snapshot(opened: [0, 1, 30, 31])
        #expect(MonthInsightGoalDay(snapshot: fixture, metric: .opened, goal: 2, at: fixture.window.end)?.day == 29)
        #expect(MonthInsightGoalDay(snapshot: fixture, metric: .opened, goal: 3, at: date(32)) == nil)
    }

    @Test func crossingDuringTheLongDayUsesTheLocalCalendar() {
        let prs = [date(1), date(1, hour: 23), date(2)].enumerated().map { index, date in
            PullRequest(id: "\(index)", title: "Fixture", url: URL(string: "https://example.test/\(index)")!,
                createdAt: date, mergedAt: nil, repository: .init(nameWithOwner: "me/app"))
        }
        let fixture = MonthSnapshot(login: "me", window: MonthWindow(containing: date(1), calendar: calendar),
            opened: prs, merged: [], totalContributions: 0, fetchedAt: date(3))
        #expect(date(2).timeIntervalSince(date(1)) == 25 * 3600)
        #expect(MonthInsightGoalDay(snapshot: fixture, metric: .opened, goal: 2, at: date(3))?.day == 0)
    }
}
