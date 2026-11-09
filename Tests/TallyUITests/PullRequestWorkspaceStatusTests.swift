import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let november = Date(timeIntervalSince1970: 1_793_491_200)  // Nov 1, 2026, 00:00 UTC

private func pr(state: PullRequest.State?, isDraft: Bool = false, merged: Bool = false) -> PullRequest {
    PullRequest(
        id: "1", title: "Title", url: URL(string: "https://github.com/me/app/pull/1")!, createdAt: november,
        mergedAt: merged ? november.addingTimeInterval(3600) : nil, repository: .init(nameWithOwner: "me/app"),
        state: state, isDraft: isDraft
    )
}

@Suite struct PullRequestWorkspaceStatusTests {
    @Test func namesEachStateGitHubReports() {
        #expect(PullRequestWorkspaceStatus(pr(state: .open))?.label == "Open")
        #expect(PullRequestWorkspaceStatus(pr(state: .open, isDraft: true))?.label == "Draft")
        #expect(PullRequestWorkspaceStatus(pr(state: .closed))?.label == "Closed")
        #expect(PullRequestWorkspaceStatus(pr(state: .merged, merged: true))?.label == "Merged")
    }

    @Test func aMergedOrClosedPullRequestIsNotADraftEvenThoughGitHubKeepsTheFlag() {
        #expect(PullRequestWorkspaceStatus(pr(state: .merged, isDraft: true, merged: true))?.kind == .merged)
        #expect(PullRequestWorkspaceStatus(pr(state: .closed, isDraft: true))?.kind == .closed)
    }

    @Test func saysNothingWhenTheStateIsUnknownRatherThanGuessingOpen() {
        #expect(PullRequestWorkspaceStatus(pr(state: nil)) == nil)
        #expect(PullRequestWorkspaceStatus.badge(for: pr(state: nil), metric: .opened) == nil)
    }

    @Test func aMergeDateIsEnoughEvenWithoutAState() {
        #expect(PullRequestWorkspaceStatus(pr(state: nil, merged: true))?.kind == .merged)
    }

    @Test func theMergedListDoesNotRepeatMergedOnEveryRow() {
        let merged = pr(state: .merged, merged: true)
        #expect(PullRequestWorkspaceStatus.badge(for: merged, metric: .merged) == nil)
        #expect(PullRequestWorkspaceStatus.badge(for: merged, metric: .opened)?.label == "Merged")
    }
}
