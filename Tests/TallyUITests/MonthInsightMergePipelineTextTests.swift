import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ day: Int) -> Date {
    newYork.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
}

/// The pipeline for a goal of merges in a November with `merged` merges and `open` PRs still open.
private func pipeline(merged: Int, open: Int, goal: Int) -> MonthInsightMergePipeline {
    let states = Array(repeating: PullRequest.State.merged, count: merged) + Array(repeating: .open, count: open)
    let prs = states.enumerated().map { index, state in
        PullRequest(
            id: "\(index)", title: "Fixture", url: URL(string: "https://example.test/\(index)")!,
            createdAt: date(2), mergedAt: state == .merged ? date(3) : nil, repository: .init(nameWithOwner: "me/app"),
            state: state
        )
    }
    let snapshot = MonthSnapshot(
        login: "me", window: MonthWindow(containing: date(1), calendar: newYork),
        opened: prs, merged: prs.filter { $0.mergedAt != nil }, totalContributions: 0, fetchedAt: date(10)
    )
    return MonthInsightMergePipeline(snapshot: snapshot, metric: .merged, goal: goal, at: date(10))!
}

@Suite struct MonthInsightMergePipelineTextTests {
    @Test func enoughStillOpenSaysTheyCouldCoverTheRest() {
        let text = MonthInsightMergePipelineText(pipeline: pipeline(merged: 20, open: 22, goal: 35), goal: 35)
        #expect(text.line == "Merges to go: 15 · 22 still open could cover them")
        #expect(text.help == "Merging 15 of the 22 PRs opened this month and still open, drafts included, reaches the goal of 35 without opening more.")
        #expect(text.spoken == "Merges to go 15, 22 still open could cover them")
    }

    @Test func oneMergeToGoIsCoveredByIt() {
        let text = MonthInsightMergePipelineText(pipeline: pipeline(merged: 4, open: 2, goal: 5), goal: 5)
        #expect(text.line == "Merges to go: 1 · 2 still open could cover it")
    }

    @Test func tooFewStillOpenSaysHowManyMoreToOpen() {
        let text = MonthInsightMergePipelineText(pipeline: pipeline(merged: 20, open: 22, goal: 1_060), goal: 1_060)
        #expect(text.line == "Merges to go: 1,040 · 22 still open, 1,018 more to open")
        #expect(text.help.contains("leaves 1,018 more to open and merge for the goal of 1,060"))
        #expect(text.help.contains("opened before this month aren't counted"))
    }

    @Test func exactlyEnoughCoversTheRestAndOneFewerFallsShortByOne() {
        #expect(
            MonthInsightMergePipelineText(pipeline: pipeline(merged: 20, open: 22, goal: 42), goal: 42).line
                == "Merges to go: 22 · 22 still open could cover them"
        )
        #expect(
            MonthInsightMergePipelineText(pipeline: pipeline(merged: 20, open: 22, goal: 43), goal: 43).line
                == "Merges to go: 23 · 22 still open, 1 more to open"
        )
    }

    @Test func noneStillOpenSaysSo() {
        let text = MonthInsightMergePipelineText(pipeline: pipeline(merged: 3, open: 0, goal: 4), goal: 4)
        #expect(text.line == "Merges to go: 1 · none still open")
        #expect(text.help.hasPrefix("None of the PRs opened this month are still open, so the 1 merge the goal of 4 still needs"))
    }
}
