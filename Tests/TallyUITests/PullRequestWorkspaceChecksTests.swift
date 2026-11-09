import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let november = Date(timeIntervalSince1970: 1_793_491_200)  // Nov 1, 2026, 00:00 UTC

private func pr(
    state: PullRequest.State? = .open, isDraft: Bool = false, merged: Bool = false, checks: PullRequest.ChecksState?
) -> PullRequest {
    PullRequest(
        id: "1", title: "Title", url: URL(string: "https://github.com/me/app/pull/1")!, createdAt: november,
        mergedAt: merged ? november.addingTimeInterval(3600) : nil, repository: .init(nameWithOwner: "me/app"),
        state: state, isDraft: isDraft, checks: checks
    )
}

@Suite struct PullRequestWorkspaceChecksTests {
    @Test func labelsAnOpenPullRequestWhoseChecksFailOrError() {
        #expect(PullRequestWorkspaceChecks(pr(checks: .failure))?.label == "CI failing")
        #expect(PullRequestWorkspaceChecks(pr(checks: .error))?.label == "CI failing")
    }

    @Test func saysNothingWhileChecksPassRunOrAreAbsent() {
        for checks in [PullRequest.ChecksState.success, .pending, .expected, nil] {
            #expect(PullRequestWorkspaceChecks(pr(checks: checks)) == nil)
        }
    }

    @Test func aDraftIsAllowedToBeRed() {
        #expect(PullRequestWorkspaceChecks(pr(isDraft: true, checks: .failure)) == nil)
    }

    @Test func aMergedClosedOrUnknownPullRequestKeepsNoLabelEvenThoughGitHubKeepsTheRollup() {
        #expect(PullRequestWorkspaceChecks(pr(state: .merged, merged: true, checks: .failure)) == nil)
        #expect(PullRequestWorkspaceChecks(pr(state: .closed, checks: .failure)) == nil)
        #expect(PullRequestWorkspaceChecks(pr(state: nil, merged: true, checks: .failure)) == nil)
        #expect(PullRequestWorkspaceChecks(pr(state: nil, checks: .failure)) == nil)
    }

    @Test func theMergedListShowsNoCheckLabels() {
        let failing = pr(checks: .failure)
        #expect(PullRequestWorkspaceChecks.badge(for: failing, metric: .merged) == nil)
        #expect(PullRequestWorkspaceChecks.badge(for: failing, metric: .opened)?.label == "CI failing")
    }
}
