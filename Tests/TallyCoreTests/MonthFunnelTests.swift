import Foundation
import Testing
@testable import TallyCore

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
    newYork.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

private func pullRequest(
    id: String = UUID().uuidString, opened: Date, merged: Date?, state: PullRequest.State? = nil, isDraft: Bool = false
) -> PullRequest {
    PullRequest(
        id: id, title: "A change", url: URL(string: "https://github.com/a/b/pull/1")!,
        createdAt: opened, mergedAt: merged, repository: .init(nameWithOwner: "a/b"), state: state, isDraft: isDraft
    )
}

private func month(opened: [PullRequest], merged: [PullRequest]) -> MonthSnapshot {
    MonthSnapshot(
        login: "someone", window: MonthWindow(containing: date(11, 1), calendar: newYork),
        opened: opened, merged: merged, totalContributions: 0, fetchedAt: date(11, 20)
    )
}

private func funnel(opened: [PullRequest], merged: [PullRequest]) -> MergeFunnel {
    month(opened: opened, merged: merged).mergeFunnel
}

@Suite struct MonthFunnelTests {
    @Test func splitsWhatWasOpenedThisMonthByWhetherItMerged() {
        let landed = pullRequest(opened: date(11, 2), merged: date(11, 3))
        let waiting = pullRequest(opened: date(11, 2), merged: nil)
        let alsoWaiting = pullRequest(opened: date(11, 2), merged: nil)
        let result = funnel(opened: [landed, waiting, alsoWaiting], merged: [landed])
        #expect(result.opened == 3)
        #expect(result.openedAndMerged == 1)
        #expect(result.notMerged == 2)
        #expect(result.mergeRate == 1.0 / 3.0)
    }

    @Test func mergesOfOlderPRsAreCarriedInAndStayOutOfTheRate() {
        let older = pullRequest(opened: date(10, 20), merged: date(11, 2))
        let alsoOlder = pullRequest(opened: date(10, 21), merged: date(11, 2))
        let landed = pullRequest(opened: date(11, 2), merged: date(11, 3))
        let result = funnel(opened: [landed], merged: [older, alsoOlder, landed])
        #expect(result.carriedIn == 2)
        #expect(result.openedAndMerged == 1)
        #expect(result.mergeRate == 1)
    }

    @Test func carriedInFollowsTheLocalMonthEdge() {
        let lastInstantOfOctober = date(11, 1).addingTimeInterval(-1)
        let result = funnel(opened: [], merged: [
            pullRequest(opened: lastInstantOfOctober, merged: date(11, 2)),
            pullRequest(opened: date(11, 1), merged: date(11, 2)),
        ])
        #expect(result.carriedIn == 1)
    }

    @Test func medianTimeToMergeCoversEverythingMergedThisMonth() {
        let result = funnel(opened: [], merged: [
            pullRequest(opened: date(10, 2), merged: date(11, 2)),
            pullRequest(opened: date(11, 2, hour: 1), merged: date(11, 2, hour: 2)),
            pullRequest(opened: date(11, 2, hour: 1), merged: date(11, 2, hour: 4)),
        ])
        #expect(result.medianTimeToMerge == TimeInterval(3 * 3600))
    }

    @Test func medianOfAnEvenCountSplitsTheMiddlePair() {
        let result = funnel(opened: [], merged: [
            pullRequest(opened: date(11, 2, hour: 1), merged: date(11, 2, hour: 2)),
            pullRequest(opened: date(11, 2, hour: 1), merged: date(11, 2, hour: 4)),
        ])
        #expect(result.medianTimeToMerge == TimeInterval(2 * 3600))
    }

    @Test func aMonthWithNothingOpenedHasNoRateAndNothingMergedHasNoMedian() {
        let older = pullRequest(opened: date(10, 20), merged: date(11, 2))
        let onlyCarried = funnel(opened: [], merged: [older])
        #expect(onlyCarried.mergeRate == nil)
        #expect(onlyCarried.isEmpty == false)

        let empty = funnel(opened: [], merged: [])
        #expect(empty.medianTimeToMerge == nil)
        #expect(empty.isEmpty)
    }

    // The two lists come from separate searches, so they can disagree about a PR that merged between them.

    @Test func aMergedCopyWinsOverAStaleOpenedCopyOfTheSamePR() {
        let stale = pullRequest(id: "same", opened: date(11, 2, hour: 1), merged: nil)
        let fresh = pullRequest(id: "same", opened: date(11, 2, hour: 1), merged: date(11, 2, hour: 2))
        let result = funnel(opened: [stale], merged: [fresh])
        #expect(result.opened == 1)
        #expect(result.openedAndMerged == 1)
        #expect(result.notMerged == 0)
        #expect(result.medianTimeToMerge == TimeInterval(3600))
    }

    @Test func aThisMonthMergeMissingFromOpenedStillCountsAsOpened() {
        let landed = pullRequest(opened: date(11, 2, hour: 1), merged: date(11, 2, hour: 2))
        let result = funnel(opened: [], merged: [landed])
        #expect(result.opened == 1)
        #expect(result.openedAndMerged == 1)
        #expect(result.carriedIn == 0)
        #expect(result.medianTimeToMerge == TimeInterval(3600))
    }

    @Test func aThisMonthMergeMissingFromMergedStillCounts() {
        let landed = pullRequest(opened: date(11, 2, hour: 1), merged: date(11, 2, hour: 2))
        let result = funnel(opened: [landed], merged: [])
        #expect(result.opened == 1)
        #expect(result.openedAndMerged == 1)
        #expect(result.medianTimeToMerge == TimeInterval(3600))
    }

    @Test func everyFigureCoversTheSameMergesWhenTheListsDisagree() {
        let landed = pullRequest(opened: date(11, 2, hour: 1), merged: date(11, 2, hour: 2))
        let older = pullRequest(opened: date(10, 1), merged: date(11, 2))
        let result = funnel(opened: [landed], merged: [older])
        #expect(result.openedAndMerged + result.carriedIn == 2)
        #expect(result.openedAndMerged == 1)
        #expect(result.carriedIn == 1)
        #expect(result.medianTimeToMerge == (TimeInterval(3600) + date(11, 2).timeIntervalSince(date(10, 1))) / 2)
    }

    @Test func aPRInBothListsOrRepeatedInOneCountsOnce() {
        let landed = pullRequest(opened: date(11, 2, hour: 1), merged: date(11, 2, hour: 2))
        let waiting = pullRequest(opened: date(11, 2), merged: nil)
        let older = pullRequest(opened: date(10, 1), merged: date(11, 2))
        let result = funnel(opened: [landed, landed, waiting, waiting], merged: [landed, landed, older, older])
        #expect(result.opened == 2)
        #expect(result.openedAndMerged == 1)
        #expect(result.carriedIn == 1)
        #expect(result.medianTimeToMerge == (TimeInterval(3600) + date(11, 2).timeIntervalSince(date(10, 1))) / 2)
    }

    @Test func aMergeOutsideTheMonthIsNotAMergeThisMonth() {
        let mergedLastMonth = pullRequest(opened: date(10, 1), merged: date(10, 2))
        let mergedNextMonth = pullRequest(opened: date(11, 2), merged: date(12, 1))
        let result = funnel(opened: [mergedNextMonth], merged: [mergedLastMonth])
        #expect(result.opened == 1)
        #expect(result.openedAndMerged == 0)
        #expect(result.notMerged == 1)
        #expect(result.carriedIn == 0)
        #expect(result.medianTimeToMerge == nil)
    }

    // The PRs behind the not-merged figure, which the popover lists when the funnel is clicked.

    @Test func theNotMergedPRsAreTheOnesTheFunnelCounts() {
        let landed = pullRequest(id: "landed", opened: date(11, 2), merged: date(11, 3))
        let waiting = pullRequest(id: "waiting", opened: date(11, 4), merged: nil)
        let mergedNextMonth = pullRequest(id: "later", opened: date(11, 5), merged: date(12, 1))
        let older = pullRequest(id: "older", opened: date(10, 1), merged: date(11, 2))
        let snapshot = month(opened: [landed, waiting, mergedNextMonth], merged: [landed, older])
        #expect(snapshot.notMergedPullRequests.map(\.id) == ["waiting", "later"])
        #expect(snapshot.notMergedPullRequests.count == snapshot.mergeFunnel.notMerged)
    }

    @Test func aStaleOpenedCopyOfAMergedPRIsNotListedAsNotMerged() {
        let stale = pullRequest(id: "same", opened: date(11, 2, hour: 1), merged: nil)
        let fresh = pullRequest(id: "same", opened: date(11, 2, hour: 1), merged: date(11, 2, hour: 2))
        let snapshot = month(opened: [stale, stale], merged: [fresh])
        #expect(snapshot.notMergedPullRequests.isEmpty)
        #expect(snapshot.mergeFunnel.notMerged == 0)
    }

    @Test func aPRRepeatedInTheOpenedListIsListedOnce() {
        let waiting = pullRequest(id: "waiting", opened: date(11, 4), merged: nil)
        let snapshot = month(opened: [waiting, waiting], merged: [])
        #expect(snapshot.notMergedPullRequests.map(\.id) == ["waiting"])
        #expect(snapshot.mergeFunnel.notMerged == 1)
    }

    // Where the not-merged PRs stand now: still open, or closed without merging.

    @Test func theNotMergedSplitIntoStillOpenAndClosed() {
        let landed = pullRequest(opened: date(11, 2), merged: date(11, 3), state: .merged)
        let open = pullRequest(opened: date(11, 4), merged: nil, state: .open)
        let draft = pullRequest(opened: date(11, 5), merged: nil, state: .open, isDraft: true)
        let closed = pullRequest(opened: date(11, 6), merged: nil, state: .closed)
        let result = funnel(opened: [landed, open, draft, closed], merged: [landed])
        #expect(result.stillOpen == 2)
        #expect(result.closedWithoutMerging == 1)
        #expect(result.notMerged == 3)
    }

    @Test func aMergeOrAnOlderPRIsNeverStillOpen() {
        // A stale opened copy still says open, but the merged list has it merged.
        let stale = pullRequest(id: "same", opened: date(11, 2, hour: 1), merged: nil, state: .open)
        let fresh = pullRequest(id: "same", opened: date(11, 2, hour: 1), merged: date(11, 2, hour: 2), state: .merged)
        let olderStillOpen = pullRequest(opened: date(10, 2), merged: nil, state: .open)
        let waiting = pullRequest(opened: date(11, 4), merged: nil, state: .open)
        let result = funnel(opened: [stale, olderStillOpen, waiting, waiting], merged: [fresh])
        #expect(result.stillOpen == 1)
        #expect(result.closedWithoutMerging == 0)
    }

    @Test func anUnknownStateLeavesTheSplitOutRatherThanGuess() {
        let open = pullRequest(opened: date(11, 4), merged: nil, state: .open)
        let unknown = pullRequest(opened: date(11, 5), merged: nil)
        let result = funnel(opened: [open, unknown], merged: [])
        #expect(result.notMerged == 2)
        #expect(result.stillOpen == nil)
        #expect(result.closedWithoutMerging == nil)
    }

    @Test func aMergeAfterAnEndedMonthIsNeitherOpenNorClosed() {
        let mergedNextMonth = pullRequest(opened: date(11, 2), merged: date(12, 1), state: .merged)
        let closed = pullRequest(opened: date(11, 3), merged: nil, state: .closed)
        let result = funnel(opened: [mergedNextMonth, closed], merged: [])
        #expect(result.notMerged == 2)
        #expect(result.stillOpen == nil)
    }

    @Test func everythingMergedSplitsIntoNothing() {
        let landed = pullRequest(opened: date(11, 2), merged: date(11, 3), state: .merged)
        let result = funnel(opened: [landed], merged: [landed])
        #expect(result.stillOpen == 0)
        #expect(result.closedWithoutMerging == 0)
    }

    // The PRs behind the carried-in figure, which the popover lists when it is clicked.

    @Test func theCarriedInPRsAreTheOnesTheFunnelCounts() {
        let older = pullRequest(id: "older", opened: date(10, 20), merged: date(11, 2))
        let lastInstantOfOctober = pullRequest(id: "edge", opened: date(11, 1).addingTimeInterval(-1), merged: date(11, 3))
        let landed = pullRequest(id: "landed", opened: date(11, 1), merged: date(11, 2))
        let mergedLastMonth = pullRequest(id: "early", opened: date(9, 1), merged: date(10, 30))
        let snapshot = month(opened: [landed], merged: [older, landed, lastInstantOfOctober, mergedLastMonth])
        #expect(snapshot.carriedInPullRequests.map(\.id) == ["older", "edge"])
        #expect(snapshot.carriedInPullRequests.count == snapshot.mergeFunnel.carriedIn)
    }

    @Test func aCarriedInPRInBothListsIsListedOnce() {
        let older = pullRequest(id: "older", opened: date(10, 20), merged: date(11, 2))
        let snapshot = month(opened: [older], merged: [older, older])
        #expect(snapshot.carriedInPullRequests.map(\.id) == ["older"])
        #expect(snapshot.mergeFunnel.carriedIn == 1)
    }
}
