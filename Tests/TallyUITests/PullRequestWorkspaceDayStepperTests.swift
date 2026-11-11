import Foundation
import Testing
import TallyCore
@testable import TallyUI

@Suite struct PullRequestWorkspaceDayStepperTests {
    private let zone = TimeZone(identifier: "America/New_York")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private func date(month: Int = 11, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    /// November 2026, on the 12th.
    private var now: Date { date(12, 15) }
    private var november: MonthWindow { MonthWindow(containing: now, calendar: calendar) }

    @Test func aPickedDayStepsToTheDaysEitherSide() {
        let stepper = PullRequestWorkspaceDayStepper(day: 6, in: november, at: now)
        #expect(stepper.title == "Nov 7")
        #expect(stepper.scope == .day(6))
        #expect(stepper.previous == .init(day: 5, title: "Nov 6"))
        #expect(stepper.next == .init(day: 7, title: "Nov 8"))
    }

    @Test func stepsStopAtTheFirstOfTheMonth() {
        let stepper = PullRequestWorkspaceDayStepper(day: 0, in: november, at: now)
        #expect(stepper.previous == nil)
        #expect(stepper.next?.day == 1)
    }

    @Test func stepsStopAtTodayBecauseLaterDaysHaveNothingYet() {
        let today = PullRequestWorkspaceDayStepper(day: 11, in: november, at: now)
        #expect(today.title == "Today")
        #expect(today.scope == .today)
        #expect(today.next == nil)
        #expect(today.previous == .init(day: 10, title: "Nov 11"))
    }

    @Test func steppingOntoTodayNamesItTodayAndUsesTheTodayScope() {
        let yesterday = PullRequestWorkspaceDayStepper(day: 10, in: november, at: now)
        #expect(yesterday.next == .init(day: 11, title: "Today"))
        let stepped = PullRequestWorkspaceDayStepper(day: yesterday.next!.day, in: november, at: now)
        #expect(stepped.scope == .today)
    }

    @Test func aDayPastTodayIsHeldAtToday() {
        let stepper = PullRequestWorkspaceDayStepper(day: 20, in: november, at: now)
        #expect(stepper.day == 11)
        #expect(stepper.scope == .today)
    }

    @Test func anEndedMonthStepsThroughItsLastDayAndCallsNoDayToday() {
        let december = date(month: 12, 2, 9)
        let last = PullRequestWorkspaceDayStepper(day: 29, in: november, at: december)
        #expect(last.title == "Nov 30")
        #expect(last.scope == .day(29))
        #expect(last.next == nil)
        #expect(PullRequestWorkspaceDayStepper(day: 28, in: november, at: december).next == .init(day: 29, title: "Nov 30"))
    }

    @Test func theDaySegmentStartsOnThePickedDayOrElseToday() {
        #expect(PullRequestWorkspaceDayStepper.openingDay(for: .day(3), in: november, at: now) == 3)
        #expect(PullRequestWorkspaceDayStepper.openingDay(for: .today, in: november, at: now) == 11)
        #expect(PullRequestWorkspaceDayStepper.openingDay(for: .month, in: november, at: now) == 11)
        #expect(PullRequestWorkspaceDayStepper.openingDay(for: .month, in: november, at: date(month: 12, 2, 9)) == 29)
    }

    @Test func aSteppedDayListsWhatThatDayCounts() {
        let prs = [6, 7, 7, 12].enumerated().map { index, day in
            PullRequest(
                id: "\(index)", title: "PR \(index)", url: URL(string: "https://github.com/me/app/pull/\(index)")!,
                createdAt: date(day, 10), mergedAt: nil, repository: .init(nameWithOwner: "me/app")
            )
        }
        let snapshot = MonthSnapshot(
            login: "me", window: november, opened: prs, merged: [], totalContributions: 0, fetchedAt: now
        )
        let picked = PullRequestWorkspaceDayStepper(day: 5, in: november, at: now)
        let stepped = PullRequestWorkspaceDayStepper(day: picked.next!.day, in: november, at: now)
        #expect(snapshot.listedPullRequests(for: .opened, scope: picked.scope, at: now).map(\.id) == ["0"])
        #expect(snapshot.listedPullRequests(for: .opened, scope: stepped.scope, at: now).count == 2)
    }
}
