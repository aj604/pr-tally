import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let november = Date(timeIntervalSince1970: 1_793_491_200)  // Nov 1, 2026, 00:00 UTC

private func pr(
    _ id: String, state: PullRequest.State?, isDraft: Bool = false, merged: Bool = false,
    review: PullRequest.ReviewDecision? = nil
) -> PullRequest {
    PullRequest(
        id: id, title: "PR \(id)", url: URL(string: "https://github.com/me/app/pull/\(id)")!, createdAt: november,
        mergedAt: merged ? november.addingTimeInterval(3600) : nil, repository: .init(nameWithOwner: "me/app"),
        state: state, isDraft: isDraft, reviewDecision: review
    )
}

private let mixed = [
    pr("1", state: .open, review: .reviewRequired),
    pr("2", state: .open, review: .approved),
    pr("3", state: .open, review: .approved),
    pr("4", state: .open, isDraft: true, review: .reviewRequired),
    pr("5", state: .closed),
    pr("6", state: .merged, merged: true, review: .approved),
]

@Suite struct PullRequestWorkspaceStatusFilterTests {
    @Test func offersOnlyChoicesSomePullRequestMatchesWithCountsInReadingOrder() {
        let filter = PullRequestWorkspaceStatusFilter(mixed)
        #expect(filter.options.map(\.title) == [
            "Open (3)", "Draft (1)", "Merged (1)", "Closed (1)", "Needs review (1)", "Approved (2)",
        ])
        #expect(filter.totalCount == 6)
    }

    @Test func aReviewChoiceFindsOnlyOpenPullRequestsWaitingOnThatDecision() {
        // Same rule as the row label: a draft or merged PR keeps GitHub's decision but shows none.
        let ids = PullRequestWorkspaceStatusFilter.apply(.review(.approved), to: mixed).map(\.id)
        #expect(ids == ["2", "3"])
        #expect(PullRequestWorkspaceStatusFilter.apply(.review(.reviewRequired), to: mixed).map(\.id) == ["1"])
    }

    @Test func openMeansTheOpenLabelSoDraftsAreNotCounted() {
        #expect(PullRequestWorkspaceStatusFilter.apply(.status(.open), to: mixed).map(\.id) == ["1", "2", "3"])
        #expect(PullRequestWorkspaceStatusFilter.apply(.status(.draft), to: mixed).map(\.id) == ["4"])
    }

    @Test func aMergeDateCountsAsMergedEvenWithoutARecordedState() {
        let cached = pr("7", state: nil, merged: true)
        #expect(PullRequestWorkspaceStatusFilter.apply(.status(.merged), to: [cached]).count == 1)
    }

    @Test func pullRequestsWithNoKnownStatusAreCountedNotDropped() {
        // What a relaunch shows before the first refresh: the cache keeps no state, only merge dates.
        let afterRelaunch = [pr("1", state: nil), pr("2", state: nil), pr("3", state: nil, merged: true)]
        let filter = PullRequestWorkspaceStatusFilter(afterRelaunch)
        #expect(filter.options.map(\.title) == ["Merged (1)", "Status not known yet (2)"])
        #expect(PullRequestWorkspaceStatusFilter.apply(.unknown, to: afterRelaunch).map(\.id) == ["1", "2"])
        // Known and unknown are exhaustive: every PR is in exactly one status choice.
        let statusCounts = filter.options.filter { if case .review = $0.choice { false } else { true } }.map(\.count)
        #expect(statusCounts.reduce(0, +) == filter.totalCount)
    }

    @Test func noChoicesAreOfferedWhenGitHubHasNotSaidAnythingYet() {
        let filter = PullRequestWorkspaceStatusFilter([pr("1", state: nil), pr("2", state: nil)])
        #expect(filter.options.map(\.title) == ["Status not known yet (2)"])
        #expect(!filter.isOffered)
    }

    @Test func aListOfOneKindOfPullRequestHasNothingToFilter() {
        let merged = [pr("1", state: .merged, merged: true), pr("2", state: .merged, merged: true)]
        #expect(!PullRequestWorkspaceStatusFilter(merged).isOffered)
        #expect(PullRequestWorkspaceStatusFilter(mixed).isOffered)
    }

    @Test func aSelectedChoiceStaysOfferedAtZeroSoItCanBeRemoved() {
        let onlyClosed = [pr("5", state: .closed)]
        let filter = PullRequestWorkspaceStatusFilter(onlyClosed, selected: .review(.approved))
        #expect(filter.options.map(\.title) == ["Closed (1)", "Approved (0)"])
        #expect(filter.isOffered)
        #expect(PullRequestWorkspaceStatusFilter([], selected: .status(.open)).isOffered)
    }

    @Test func noChoiceLeavesTheListAlone() {
        #expect(PullRequestWorkspaceStatusFilter.apply(nil, to: mixed) == mixed)
    }
}
