import Foundation
import Testing
@testable import TallyCore

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ month: Int, _ day: Int) -> Date {
    newYork.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
}

private let window = MonthWindow(containing: date(11, 1), calendar: newYork)

/// A November with `carriedIn` merges of October PRs, then PRs opened on the 2nd: `merged` merged on the 3rd, `open`
/// still open, `drafts` open as drafts, `closed` closed without merging, and `unknown` saved before states were fetched.
private func month(carriedIn: Int = 0, merged: Int = 0, open: Int = 0, drafts: Int = 0, closed: Int = 0, unknown: Int = 0) -> MonthSnapshot {
    func prs(_ count: Int, _ name: String, opened: Date, merged: Date? = nil, state: PullRequest.State?, isDraft: Bool = false) -> [PullRequest] {
        (0..<count).map { index in
            PullRequest(
                id: "\(name)\(index)", title: "A change", url: URL(string: "https://github.com/a/b/pull/\(index)")!,
                createdAt: opened, mergedAt: merged, repository: .init(nameWithOwner: "a/b"), state: state, isDraft: isDraft
            )
        }
    }
    let older = prs(carriedIn, "older", opened: date(10, 20), merged: date(11, 3), state: .merged)
    let landed = prs(merged, "landed", opened: date(11, 2), merged: date(11, 3), state: .merged)
    let opened = landed
        + prs(open, "open", opened: date(11, 2), state: .open)
        + prs(drafts, "draft", opened: date(11, 2), state: .open, isDraft: true)
        + prs(closed, "closed", opened: date(11, 2), state: .closed)
        + prs(unknown, "unknown", opened: date(11, 2), state: nil)
    return MonthSnapshot(
        login: "someone", window: window, opened: opened, merged: older + landed, totalContributions: 0, fetchedAt: date(11, 10)
    )
}

@Suite struct MonthInsightMergePipelineTests {
    @Test func weighsTheMergesStillNeededAgainstThePRsStillOpenDraftsIncluded() throws {
        let snapshot = month(carriedIn: 2, merged: 4, open: 5, drafts: 2, closed: 3)
        let pipeline = try #require(MonthInsightMergePipeline(snapshot: snapshot, metric: .merged, goal: 20, at: date(11, 10)))
        #expect(pipeline.remaining == 14)
        #expect(pipeline.stillOpen == 7)
        #expect(pipeline.shortfall == 7)
    }

    @Test func agreesWithPaceAndTheFunnel() throws {
        let snapshot = month(carriedIn: 3, merged: 6, open: 4, closed: 2)
        let now = date(11, 10)
        let pipeline = try #require(MonthInsightMergePipeline(snapshot: snapshot, metric: .merged, goal: 30, at: now))
        let pace = Pace(goal: 30, count: snapshot.count(for: .merged), window: window, at: now)
        #expect(pipeline.remaining == pace.remaining)
        #expect(pipeline.stillOpen == snapshot.mergeFunnel.stillOpen)
    }

    @Test func enoughStillOpenLeavesNoShortfall() throws {
        let pipeline = try #require(
            MonthInsightMergePipeline(snapshot: month(merged: 4, open: 9), metric: .merged, goal: 10, at: date(11, 10))
        )
        #expect(pipeline.shortfall == 0)
    }

    @Test func aGoalOfOpenedPRsHasNoMergesToWeigh() {
        #expect(MonthInsightMergePipeline(snapshot: month(merged: 4, open: 9), metric: .opened, goal: 50, at: date(11, 10)) == nil)
    }

    @Test func aReachedGoalHasNothingLeftToWeigh() {
        let snapshot = month(merged: 5, open: 9)
        #expect(MonthInsightMergePipeline(snapshot: snapshot, metric: .merged, goal: 5, at: date(11, 10)) == nil)
        #expect(MonthInsightMergePipeline(snapshot: snapshot, metric: .merged, goal: 0, at: date(11, 10)) == nil)
    }

    @Test func anUnknownStateSaysNothingRatherThanCountItAsOpen() {
        let snapshot = month(merged: 4, open: 3, unknown: 1)
        #expect(MonthInsightMergePipeline(snapshot: snapshot, metric: .merged, goal: 20, at: date(11, 10)) == nil)
    }

    @Test func nothingOutsideTheMonthSinceNoMoreMergesCanCount() {
        let snapshot = month(merged: 4, open: 9)
        #expect(MonthInsightMergePipeline(snapshot: snapshot, metric: .merged, goal: 20, at: window.end) == nil)
        #expect(MonthInsightMergePipeline(snapshot: snapshot, metric: .merged, goal: 20, at: date(10, 31)) == nil)
    }
}
