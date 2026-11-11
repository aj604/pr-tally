import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let november = Date(timeIntervalSince1970: 1_793_491_200)  // Nov 1, 2026, 00:00 UTC

private func pr(state: PullRequest.State?, isDraft: Bool = false, mergedAfter seconds: TimeInterval? = nil) -> PullRequest {
    PullRequest(
        id: "1", title: "Title", url: URL(string: "https://github.com/me/app/pull/1")!, createdAt: november,
        mergedAt: seconds.map { november.addingTimeInterval($0) }, repository: .init(nameWithOwner: "me/app"),
        state: state, isDraft: isDraft
    )
}

private func openTime(_ pr: PullRequest, after seconds: TimeInterval) -> PullRequestWorkspaceOpenTime? {
    PullRequestWorkspaceOpenTime(pr, at: november.addingTimeInterval(seconds))
}

@Suite struct PullRequestWorkspaceOpenTimeTests {
    @Test func saysHowLongAnOpenOrDraftPullRequestHasWaited() {
        #expect(openTime(pr(state: .open), after: 3 * 86_400 + 3_600)?.label == "Open for 3d")
        #expect(openTime(pr(state: .open, isDraft: true), after: 5 * 3_600)?.label == "Draft for 5h")
        #expect(openTime(pr(state: .open), after: 25 * 60)?.label == "Open for 25m")
    }

    @Test func roundsAsTheMergeTimeDoes() {
        #expect(openTime(pr(state: .open), after: 23 * 3_600 + 40 * 60)?.label == "Open for 1d")
        #expect(openTime(pr(state: .open), after: 10)?.label == "Open for 1m")
        // Opened after the snapshot's clock, as skew between GitHub and this Mac could show.
        #expect(openTime(pr(state: .open), after: -300)?.label == "Open for 1m")
    }

    @Test func saysNothingForAPullRequestThatIsNotWaiting() {
        #expect(openTime(pr(state: .merged, mergedAfter: 60), after: 3_600) == nil)
        // A merge date is proof of merging even where the state reads open, as in a snapshot taken mid-merge.
        #expect(openTime(pr(state: .open, mergedAfter: 60), after: 3_600) == nil)
        #expect(openTime(pr(state: .closed), after: 3_600) == nil)
        #expect(openTime(pr(state: nil), after: 3_600) == nil)
    }

    @Test func takesTheStatussColourAndReadsOutTheUnitInWords() {
        let open = openTime(pr(state: .open), after: 86_400)
        #expect(open?.tint == PullRequestWorkspaceStatus(pr(state: .open))?.tint)
        #expect(open?.accessibilityLabel == "Open for 1 day")
        #expect(openTime(pr(state: .open, isDraft: true), after: 2 * 3_600)?.accessibilityLabel == "Draft for 2 hours")
    }
}
