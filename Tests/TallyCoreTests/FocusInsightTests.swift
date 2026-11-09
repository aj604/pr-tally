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

private func pr(
    _ id: String, repo: String = "me/app", mergedAfter hours: Double? = nil, state: PullRequest.State? = nil,
    isDraft: Bool = false, lines: Int? = nil
) -> PullRequest {
    PullRequest(
        id: id, title: "Fixture", url: URL(string: "https://example.test/\(id)")!, createdAt: date(3),
        mergedAt: hours.map { date(3).addingTimeInterval($0 * 3_600) }, repository: .init(nameWithOwner: repo),
        state: state, isDraft: isDraft, additions: lines.map { $0 - $0 / 4 }, deletions: lines.map { $0 / 4 }
    )
}

@Suite struct FocusInsightTests {
    @Test func theShareIsTheSliceOverTheMonth() {
        let insight = FocusInsight(pullRequests: [pr("a"), pr("b")], monthCount: 8)
        #expect(insight.count == 2)
        #expect(insight.share == 0.25)
        #expect(FocusInsight(pullRequests: [], monthCount: 0).share == nil)
    }

    @Test func theMedianMergeTimeIsTheMiddleOneOrTheMeanOfTheMiddleTwo() {
        let odd = FocusInsight(pullRequests: [pr("a", mergedAfter: 1), pr("b", mergedAfter: 9), pr("c", mergedAfter: 4)], monthCount: 3)
        #expect(odd.merged == 3)
        #expect(odd.medianTimeToMerge == TimeInterval(4 * 3_600))
        let even = FocusInsight(pullRequests: [pr("a", mergedAfter: 1), pr("b", mergedAfter: 3), pr("c")], monthCount: 3)
        #expect(even.merged == 2)
        #expect(even.medianTimeToMerge == TimeInterval(2 * 3_600))
        #expect(FocusInsight(pullRequests: [pr("a")], monthCount: 1).medianTimeToMerge == nil)
    }

    @Test func openDraftAndClosedCountOnlyStatesGitHubReported() {
        let insight = FocusInsight(
            pullRequests: [
                pr("open", state: .open), pr("draft", state: .open, isDraft: true), pr("closed", state: .closed),
                pr("unknown"), pr("merged", state: .merged), pr("mergedDraft", mergedAfter: 2, state: .merged, isDraft: true),
            ],
            monthCount: 6
        )
        #expect(insight.open == 1)
        #expect(insight.draft == 1)
        #expect(insight.closed == 1)
        // Merged by state alone still counts, though without a date it has no merge time.
        #expect(insight.merged == 2)
        #expect(insight.medianTimeToMerge == TimeInterval(2 * 3_600))
    }

    @Test func theOldestOpenIsTheEarliestOpenedThatIsOpenAndNotADraft() {
        func opened(_ id: String, day: Int, state: PullRequest.State? = .open, isDraft: Bool = false) -> PullRequest {
            PullRequest(
                id: id, title: "Fixture", url: URL(string: "https://example.test/\(id)")!, createdAt: date(day),
                mergedAt: nil, repository: .init(nameWithOwner: "me/app"), state: state, isDraft: isDraft
            )
        }
        let insight = FocusInsight(
            pullRequests: [
                opened("newer", day: 6), opened("older", day: 4), opened("draft", day: 1, isDraft: true),
                opened("closed", day: 1, state: .closed), opened("unknown", day: 1, state: nil),
            ],
            monthCount: 5
        )
        #expect(insight.oldestOpenSince == date(4))
        #expect(FocusInsight(pullRequests: [opened("draft", day: 1, isDraft: true)], monthCount: 1).oldestOpenSince == nil)
    }

    @Test func theMedianSizeSkipsPullRequestsWhoseSizeIsUnknown() {
        let odd = FocusInsight(pullRequests: [pr("a", lines: 10), pr("b", lines: 400), pr("c", lines: 40), pr("d")], monthCount: 4)
        #expect(odd.medianLinesChanged == 40)
        let even = FocusInsight(pullRequests: [pr("a", lines: 10), pr("b", lines: 30)], monthCount: 2)
        #expect(even.medianLinesChanged == 20)
        #expect(FocusInsight(pullRequests: [pr("a"), pr("b")], monthCount: 2).medianLinesChanged == nil)
    }

    @Test func theMonthsMedianSizeIsOverTheMetricsPullRequests() {
        let opened = [pr("a", lines: 10), pr("b", lines: 20), pr("c", lines: 900)]
        let snapshot = MonthSnapshot(
            login: "me", window: MonthWindow(containing: date(1), calendar: calendar), opened: opened,
            merged: [pr("c", mergedAfter: 1, lines: 900)], totalContributions: 0, fetchedAt: date(5)
        )
        #expect(snapshot.medianLinesChanged(for: .opened) == 20)
        #expect(snapshot.medianLinesChanged(for: .merged) == 900)
    }

    @Test func theMonthsMedianMergeTimeIsOverTheMetricsMergedPullRequests() {
        let opened = [pr("a", mergedAfter: 2), pr("b", mergedAfter: 10), pr("c"), pr("d", state: .merged)]
        let snapshot = MonthSnapshot(
            login: "me", window: MonthWindow(containing: date(1), calendar: calendar), opened: opened,
            merged: [pr("b", mergedAfter: 10)], totalContributions: 0, fetchedAt: date(5)
        )
        // Unmerged PRs, and one merged by state alone with no date, have no time to measure.
        #expect(snapshot.medianTimeToMerge(for: .opened) == TimeInterval(6 * 3_600))
        #expect(snapshot.medianTimeToMerge(for: .merged) == TimeInterval(10 * 3_600))
        let none = MonthSnapshot(
            login: "me", window: snapshot.window, opened: [pr("c")], merged: [], totalContributions: 0, fetchedAt: date(5)
        )
        #expect(none.medianTimeToMerge(for: .opened) == nil)
    }

    @Test func repositoriesRankByCountThenName() {
        let insight = FocusInsight(pullRequests: [pr("a", repo: "z/z"), pr("b", repo: "a/a"), pr("c", repo: "m/m"), pr("d", repo: "m/m")], monthCount: 4)
        #expect(insight.repositories.map(\.name) == ["m/m", "a/a", "z/z"])
    }

    @Test func theAveragePerFinishedDayLeavesTodayOut() {
        let prs = (0..<10).map { PullRequest(id: "\($0)", title: "", url: URL(string: "https://example.test")!, createdAt: date(1), mergedAt: nil, repository: .init(nameWithOwner: "me/app")) }
        let today = PullRequest(id: "t", title: "", url: URL(string: "https://example.test")!, createdAt: date(5, hour: 8), mergedAt: nil, repository: .init(nameWithOwner: "me/app"))
        let snapshot = MonthSnapshot(
            login: "me", window: MonthWindow(containing: date(1), calendar: calendar), opened: prs + [today], merged: [],
            totalContributions: 0, fetchedAt: date(5)
        )
        // Four days finished before the 5th, whose PR waits for the day to end.
        #expect(snapshot.averagePerFinishedDay(for: .opened, at: date(5, hour: 9)) == 2.5)
        #expect(snapshot.averagePerFinishedDay(for: .opened, at: date(1, hour: 9)) == nil)
        #expect(snapshot.averagePerFinishedDay(for: .opened, at: date(1).addingTimeInterval(-1)) == nil)
        // Once the month is over every day has finished.
        #expect(snapshot.averagePerFinishedDay(for: .opened, at: date(30).addingTimeInterval(86_400)) == 11.0 / 30)
    }

    @Test func theAverageByTimeOfDayCountsOnlyTheSameHoursOfFinishedDays() {
        func opened(_ id: String, day: Int, hour: Int) -> PullRequest {
            PullRequest(id: id, title: "", url: URL(string: "https://example.test")!, createdAt: date(day, hour: hour), mergedAt: nil, repository: .init(nameWithOwner: "me/app"))
        }
        // Two finished days: the 1st opened at 8 and 20, the 2nd at 9; today has one at 7.
        let prs = [opened("a", day: 1, hour: 8), opened("b", day: 1, hour: 20), opened("c", day: 2, hour: 9), opened("t", day: 3, hour: 7)]
        let snapshot = MonthSnapshot(
            login: "me", window: MonthWindow(containing: date(1), calendar: calendar), opened: prs, merged: [],
            totalContributions: 0, fetchedAt: date(3)
        )
        #expect(snapshot.averageByTimeOfDay(for: .opened, at: date(3, hour: 6)) == 0)
        #expect(snapshot.averageByTimeOfDay(for: .opened, at: date(3, hour: 10)) == 1)
        #expect(snapshot.averageByTimeOfDay(for: .opened, at: date(3, hour: 23)) == 1.5)
        // Merged counts by merge time, so a PR opened early and merged late counts late.
        let merged = [PullRequest(id: "m", title: "", url: URL(string: "https://example.test")!, createdAt: date(1, hour: 1), mergedAt: date(1, hour: 22), repository: .init(nameWithOwner: "me/app"))]
        let merges = MonthSnapshot(
            login: "me", window: snapshot.window, opened: [], merged: merged, totalContributions: 0, fetchedAt: date(3)
        )
        #expect(merges.averageByTimeOfDay(for: .merged, at: date(3, hour: 21)) == 0)
        #expect(merges.averageByTimeOfDay(for: .merged, at: date(3, hour: 23)) == 0.5)
        // No finished day on the 1st, and none outside the month.
        #expect(snapshot.averageByTimeOfDay(for: .opened, at: date(1, hour: 23)) == nil)
        #expect(snapshot.averageByTimeOfDay(for: .opened, at: date(1).addingTimeInterval(-1)) == nil)
    }
}
