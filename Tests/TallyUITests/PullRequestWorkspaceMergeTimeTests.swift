import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let november = Date(timeIntervalSince1970: 1_793_491_200)  // Nov 1, 2026, 00:00 UTC

private func pr(mergedAfter seconds: TimeInterval?, state: PullRequest.State? = .merged) -> PullRequest {
    PullRequest(
        id: "1", title: "Title", url: URL(string: "https://github.com/me/app/pull/1")!, createdAt: november,
        mergedAt: seconds.map { november.addingTimeInterval($0) }, repository: .init(nameWithOwner: "me/app"),
        state: state
    )
}

private func label(_ seconds: TimeInterval) -> String? {
    PullRequestWorkspaceMergeTime(pr(mergedAfter: seconds))?.label
}

@Suite struct PullRequestWorkspaceMergeTimeTests {
    @Test func saysNothingUntilThePullRequestMerges() {
        #expect(PullRequestWorkspaceMergeTime(pr(mergedAfter: nil, state: .open)) == nil)
        #expect(PullRequestWorkspaceMergeTime(pr(mergedAfter: nil, state: .closed)) == nil)
    }

    @Test func roundsToMinutesUnderAnHourHoursUnderADayAndDaysFromThere() {
        #expect(label(25 * 60) == "Merged in 25m")
        #expect(label(5 * 3_600 + 20 * 60) == "Merged in 5h")
        #expect(label(5 * 3_600 + 40 * 60) == "Merged in 6h")
        #expect(label(3 * 86_400 + 2 * 3_600) == "Merged in 3d")
        #expect(label(40 * 86_400) == "Merged in 40d")
    }

    @Test func roundingUpToTheNextUnitMovesToThatUnit() {
        #expect(label(59 * 60 + 40) == "Merged in 1h")
        #expect(label(23 * 3_600 + 40 * 60) == "Merged in 1d")
        #expect(label(36 * 3_600) == "Merged in 2d")
    }

    @Test func neverReadsLessThanAMinute() {
        #expect(label(10) == "Merged in 1m")
        #expect(label(0) == "Merged in 1m")
        // Merged before it was opened, as clock skew between GitHub's records could show.
        #expect(label(-300) == "Merged in 1m")
    }

    @Test func aPullRequestMergedWithoutARecordedStateStillShowsIt() {
        #expect(PullRequestWorkspaceMergeTime(pr(mergedAfter: 3_600, state: nil))?.label == "Merged in 1h")
    }

    @Test func readsOutTheUnitInWords() {
        #expect(PullRequestWorkspaceMergeTime(pr(mergedAfter: 60))?.accessibilityLabel == "Merged in 1 minute")
        #expect(PullRequestWorkspaceMergeTime(pr(mergedAfter: 5 * 3_600))?.accessibilityLabel == "Merged in 5 hours")
        #expect(PullRequestWorkspaceMergeTime(pr(mergedAfter: 86_400))?.accessibilityLabel == "Merged in 1 day")
    }
}
