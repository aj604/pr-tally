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

private func pr(_ id: String, opened: Date, merged: Date? = nil, in repository: String = "me/app") -> PullRequest {
    PullRequest(
        id: id, title: "Title \(id)", url: URL(string: "https://github.com/\(repository)/pull/\(id)")!, createdAt: opened,
        mergedAt: merged, repository: .init(nameWithOwner: repository)
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

    @Test func aDayPickedFromTheChartListsWhatItsBarCounts() {
        let snapshot = snapshot(
            [
                pr("before", opened: date(5, 23, 59)), pr("morning", opened: date(6, 0, 1)), pr("evening", opened: date(6, 22)),
                pr("after", opened: date(7, 0)), pr("merged", opened: date(2, 9), merged: date(6, 11)),
            ],
            now: now
        )
        let opened = snapshot.listedPullRequests(for: .opened, scope: .day(5), at: now)
        #expect(opened.map(\.id) == ["evening", "morning"])
        #expect(opened.count == snapshot.dailyCounts(for: .opened)[5])
        #expect(snapshot.listedPullRequests(for: .merged, scope: .day(5), at: now).map(\.id) == ["merged"])
    }

    @Test func aRepositoryPickedFromTheTopReposListsOnlyItsPullRequests() {
        let snapshot = snapshot(
            [
                pr("a", opened: date(3, 9), in: "acme/infra"), pr("b", opened: date(12, 9)),
                pr("c", opened: date(12, 10), in: "acme/infra"), pr("d", opened: date(8, 9), in: "acme/infra"),
            ],
            now: now
        )
        let month = snapshot.listedPullRequests(for: .opened, scope: .month, repository: "acme/infra", at: now)
        #expect(month.map(\.id) == ["c", "d", "a"])
        #expect(month.count == snapshot.topRepositories(for: .opened).first { $0.name == "acme/infra" }?.count)
        #expect(snapshot.listedPullRequests(for: .opened, scope: .today, repository: "acme/infra", at: now).map(\.id) == ["c"])
        #expect(snapshot.listedPullRequests(for: .opened, scope: .day(2), repository: "me/app", at: now).isEmpty)
    }

    @Test func theListOpensOnWhatWasClicked() {
        let quiet = snapshot([pr("a", opened: date(2, 9))], now: now)
        let busy = snapshot([pr("a", opened: date(2, 9)), pr("b", opened: date(12, 9))], now: now)
        #expect(PullRequestScope.opening(for: .init(), in: quiet, metric: .opened, at: now) == .month)
        #expect(PullRequestScope.opening(for: .init(), in: busy, metric: .opened, at: now) == .today)
        #expect(PullRequestScope.opening(for: .init(day: 1), in: busy, metric: .opened, at: now) == .day(1))
        // Today's bar opens the same list the Today segment does, with the segment selected.
        #expect(PullRequestScope.opening(for: .init(day: 11), in: quiet, metric: .opened, at: now) == .today)
        // A top repo's count is the month's, even on a day it has PRs.
        #expect(PullRequestScope.opening(for: .init(repository: "me/app"), in: busy, metric: .opened, at: now) == .month)
    }

    /// The day a bar stands for, in the zone the month was counted in, whatever zone the Mac is in now.
    @Test func aDayIsNamedInTheZoneItWasCountedIn() {
        var kiribati = Calendar(identifier: .gregorian)
        kiribati.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!
        let window = MonthWindow(containing: kiribati.date(from: DateComponents(year: 2026, month: 11, day: 15))!, calendar: kiribati)
        var utc = Date.FormatStyle.dateTime.month(.abbreviated).day()
        utc.timeZone = TimeZone(identifier: "UTC")!
        let firstAtNoonUTC = Date(timeIntervalSince1970: 1_793_534_400)
        #expect(firstAtNoonUTC.formatted(utc) == window.dayTitle(0))
        #expect(window.dayTitle(29) != window.dayTitle(0))
    }

    @Test func theFunnelListsOnlyWhatWasOpenedThisMonthAndHasntMerged() {
        let snapshot = snapshot(
            [
                pr("waiting", opened: date(3, 9)), pr("landed", opened: date(4, 9), merged: date(5, 9)),
                pr("today", opened: date(12, 9), in: "acme/infra"), pr("closed", opened: date(8, 9)),
            ],
            now: now
        )
        let month = snapshot.listedPullRequests(for: .opened, scope: .month, notMerged: true, at: now)
        #expect(month.map(\.id) == ["today", "closed", "waiting"])
        #expect(month.count == snapshot.mergeFunnel.notMerged)
        // It narrows whatever else the list is narrowed to.
        #expect(snapshot.listedPullRequests(for: .opened, scope: .today, notMerged: true, at: now).map(\.id) == ["today"])
        #expect(
            snapshot.listedPullRequests(for: .opened, scope: .month, repository: "me/app", notMerged: true, at: now)
                .map(\.id) == ["closed", "waiting"]
        )
        #expect(snapshot.listedPullRequests(for: .opened, scope: .day(3), notMerged: true, at: now).isEmpty)
    }

    @Test func theFunnelOpensTheWholeMonthEvenWhenTodayHasPRs() {
        let busy = snapshot([pr("a", opened: date(2, 9)), pr("b", opened: date(12, 9))], now: now)
        #expect(PullRequestScope.opening(for: .init(metric: .opened, notMerged: true), in: busy, metric: .opened, at: now) == .month)
    }
}
