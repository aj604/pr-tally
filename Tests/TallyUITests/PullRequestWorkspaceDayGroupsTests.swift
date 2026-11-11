import Foundation
import Testing
import TallyCore
@testable import TallyUI

@Suite struct PullRequestWorkspaceDayGroupsTests {
    private let zone = TimeZone(identifier: "America/New_York")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private func date(month: Int = 11, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func pr(_ id: String, opened: Date, merged: Date? = nil) -> PullRequest {
        PullRequest(
            id: id, title: "Title \(id)", url: URL(string: "https://github.com/me/app/pull/\(id)")!, createdAt: opened,
            mergedAt: merged, repository: .init(nameWithOwner: "me/app")
        )
    }

    /// November 2026, on the 12th.
    private var now: Date { date(12, 15) }
    private var november: MonthWindow { MonthWindow(containing: now, calendar: calendar) }

    @Test func eachDayIsOneSectionNewestDayFirst() {
        let prs = [
            pr("late", opened: date(12, 14)), pr("early", opened: date(12, 9)),
            pr("evening", opened: date(7, 22)), pr("morning", opened: date(7, 0, 1)), pr("first", opened: date(1, 9)),
        ]
        let groups = PullRequestWorkspaceDayGroups(prs, metric: .opened, in: november, at: now).groups
        #expect(groups.map(\.day) == [11, 6, 0])
        #expect(groups.map(\.title) == ["Today", "Nov 7", "Nov 1"])
        #expect(groups.map { $0.pullRequests.map(\.id) } == [["late", "early"], ["evening", "morning"], ["first"]])
    }

    @Test func rowsKeepTheOrderTheyCameInWithinTheirDay() {
        let prs = [pr("a", opened: date(7, 9)), pr("b", opened: date(7, 18)), pr("c", opened: date(7, 12))]
        let groups = PullRequestWorkspaceDayGroups(prs, metric: .opened, in: november, at: now).groups
        #expect(groups.map { $0.pullRequests.map(\.id) } == [["a", "b", "c"]])
    }

    @Test func mergedPullRequestsGroupByTheDayTheyMerged() {
        let prs = [pr("old", opened: date(month: 10, 20, 9), merged: date(8, 10)), pr("quick", opened: date(3, 9), merged: date(3, 11))]
        let groups = PullRequestWorkspaceDayGroups(prs, metric: .merged, in: november, at: now).groups
        #expect(groups.map(\.day) == [7, 2])
        #expect(groups.map(\.title) == ["Nov 8", "Nov 3"])
    }

    @Test func daysAreSplitAtMidnightInTheMonthsZone() {
        let prs = [pr("after", opened: date(7, 0)), pr("before", opened: date(6, 23, 59))]
        let groups = PullRequestWorkspaceDayGroups(prs, metric: .opened, in: november, at: now).groups
        #expect(groups.map(\.day) == [6, 5])
    }

    @Test func pullRequestsCountedOutsideTheMonthAreLeftOut() {
        let prs = [pr("october", opened: date(month: 10, 31, 23)), pr("unmerged", opened: date(4, 9)), pr("in", opened: date(4, 9))]
        #expect(PullRequestWorkspaceDayGroups(prs, metric: .opened, in: november, at: now).groups.map(\.pullRequests.count) == [2])
        #expect(PullRequestWorkspaceDayGroups(prs, metric: .merged, in: november, at: now).groups.isEmpty)
    }

    @Test func anEndedMonthHasNoToday() {
        let prs = [pr("last", opened: date(30, 9))]
        let groups = PullRequestWorkspaceDayGroups(prs, metric: .opened, in: november, at: date(month: 12, 2, 9)).groups
        #expect(groups.map(\.title) == ["Nov 30"])
    }

    @Test func theCountSaysOnePROrMany() {
        let prs = [pr("a", opened: date(7, 9)), pr("b", opened: date(7, 10)), pr("c", opened: date(6, 9))]
        let groups = PullRequestWorkspaceDayGroups(prs, metric: .opened, in: november, at: now).groups
        #expect(groups.map(\.countText) == ["2 PRs", "1 PR"])
    }

    @Test func anEmptyListHasNoSections() {
        #expect(PullRequestWorkspaceDayGroups([], metric: .opened, in: november, at: now).groups.isEmpty)
    }
}
