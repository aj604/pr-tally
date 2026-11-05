import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let zone = TimeZone(identifier: "America/New_York")!
private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
}

private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func pr(_ id: String, opened: Date, merged: Date? = nil) -> PullRequest {
    PullRequest(
        id: id, title: "Title \(id)", url: URL(string: "https://github.com/me/app/pull/\(id)")!, createdAt: opened,
        mergedAt: merged, repository: .init(nameWithOwner: "me/app")
    )
}

private func snapshot(_ prs: [PullRequest], now: Date) -> MonthSnapshot {
    MonthSnapshot(
        login: "me", window: MonthWindow(containing: now, calendar: calendar), opened: prs,
        merged: prs.filter { $0.mergedAt != nil }, totalContributions: 0, fetchedAt: now
    )
}

@Suite struct PullRequestListTests {
    private let now = date(12, 15)

    @Test func todayListsOnlyTodaysPullRequestsNewestFirst() {
        let snapshot = snapshot(
            [pr("early", opened: date(12, 1)), pr("yesterday", opened: date(11, 23, 59)), pr("late", opened: date(12, 14))],
            now: now
        )
        let listed = snapshot.listedPullRequests(for: .opened, scope: .today, at: now)
        #expect(listed.map(\.id) == ["late", "early"])
        #expect(listed.count == snapshot.todayCount(for: .opened, at: now))
    }

    @Test func monthListsEveryCountedPullRequestNewestFirst() {
        let snapshot = snapshot(
            [pr("a", opened: date(2, 9)), pr("c", opened: date(12, 9)), pr("b", opened: date(7, 9))], now: now
        )
        #expect(snapshot.listedPullRequests(for: .opened, scope: .month, at: now).map(\.id) == ["c", "b", "a"])
        #expect(snapshot.listedPullRequests(for: .opened, scope: .month, at: now).count == snapshot.count(for: .opened))
    }

    @Test func mergedListsByWhenTheyMergedNotWhenTheyOpened() {
        let snapshot = snapshot(
            [
                pr("old", opened: date(3, 9), merged: date(12, 10)),
                pr("open", opened: date(12, 9)),
                pr("new", opened: date(12, 8), merged: date(12, 13)),
            ],
            now: now
        )
        #expect(snapshot.listedPullRequests(for: .merged, scope: .today, at: now).map(\.id) == ["new", "old"])
        #expect(snapshot.listedPullRequests(for: .opened, scope: .today, at: now).map(\.id) == ["open", "new"])
    }

    @Test func aDayWithNothingIsEmpty() {
        let snapshot = snapshot([pr("a", opened: date(2, 9))], now: now)
        #expect(snapshot.listedPullRequests(for: .opened, scope: .today, at: now).isEmpty)
    }
}
