import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let november = Date(timeIntervalSince1970: 1_793_491_200)  // Nov 1, 2026, 00:00 UTC

private func pr(
    state: PullRequest.State? = .open, isDraft: Bool = false, merged: Bool = false,
    review: PullRequest.ReviewDecision?
) -> PullRequest {
    PullRequest(
        id: "1", title: "Title", url: URL(string: "https://github.com/me/app/pull/1")!, createdAt: november,
        mergedAt: merged ? november.addingTimeInterval(3600) : nil, repository: .init(nameWithOwner: "me/app"),
        state: state, isDraft: isDraft, reviewDecision: review
    )
}

@Suite struct PullRequestWorkspaceReviewTests {
    @Test func namesEachDecisionOnAnOpenPullRequest() {
        #expect(PullRequestWorkspaceReview(pr(review: .approved))?.label == "Approved")
        #expect(PullRequestWorkspaceReview(pr(review: .changesRequested))?.label == "Changes requested")
        #expect(PullRequestWorkspaceReview(pr(review: .reviewRequired))?.label == "Needs review")
    }

    @Test func saysNothingWhenGitHubReportsNoDecision() {
        #expect(PullRequestWorkspaceReview(pr(review: nil)) == nil)
    }

    @Test func aDraftIsNotWaitingOnReview() {
        #expect(PullRequestWorkspaceReview(pr(isDraft: true, review: .reviewRequired)) == nil)
    }

    @Test func aMergedOrClosedPullRequestKeepsNoReviewLabelEvenThoughGitHubKeepsTheDecision() {
        #expect(PullRequestWorkspaceReview(pr(state: .merged, merged: true, review: .approved)) == nil)
        #expect(PullRequestWorkspaceReview(pr(state: .closed, review: .changesRequested)) == nil)
        // A merge date alone is proof enough, as for the status label.
        #expect(PullRequestWorkspaceReview(pr(state: nil, merged: true, review: .approved)) == nil)
    }

    @Test func anUnknownStateGetsNoLabelRatherThanAGuessedOpen() {
        #expect(PullRequestWorkspaceReview(pr(state: nil, review: .approved)) == nil)
    }

    @Test func theMergedListShowsNoReviewLabels() {
        let open = pr(review: .approved)
        #expect(PullRequestWorkspaceReview.badge(for: open, metric: .merged) == nil)
        #expect(PullRequestWorkspaceReview.badge(for: open, metric: .opened)?.label == "Approved")
    }
}
