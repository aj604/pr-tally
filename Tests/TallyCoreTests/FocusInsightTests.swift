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
    isDraft: Bool = false
) -> PullRequest {
    PullRequest(
        id: id, title: "Fixture", url: URL(string: "https://example.test/\(id)")!, createdAt: date(3),
        mergedAt: hours.map { date(3).addingTimeInterval($0 * 3_600) }, repository: .init(nameWithOwner: repo),
        state: state, isDraft: isDraft
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

    @Test func repositoriesRankByCountThenName() {
        let insight = FocusInsight(pullRequests: [pr("a", repo: "z/z"), pr("b", repo: "a/a"), pr("c", repo: "m/m"), pr("d", repo: "m/m")], monthCount: 4)
        #expect(insight.repositories.map(\.name) == ["m/m", "a/a", "z/z"])
    }

    @Test func theAveragePerDayCountsTodayAmongTheDaysSoFar() {
        let prs = (0..<10).map { PullRequest(id: "\($0)", title: "", url: URL(string: "https://example.test")!, createdAt: date(1), mergedAt: nil, repository: .init(nameWithOwner: "me/app")) }
        let snapshot = MonthSnapshot(
            login: "me", window: MonthWindow(containing: date(1), calendar: calendar), opened: prs, merged: [],
            totalContributions: 0, fetchedAt: date(5)
        )
        #expect(snapshot.averagePerDay(for: .opened, at: date(5, hour: 9)) == 2)
        #expect(snapshot.averagePerDay(for: .opened, at: date(1).addingTimeInterval(-1)) == nil)
    }
}
