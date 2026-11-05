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

private func pullRequest(opened: Date, merged: Date?) -> PullRequest {
    PullRequest(
        id: UUID().uuidString, title: "A change", url: URL(string: "https://github.com/a/b/pull/1")!,
        createdAt: opened, mergedAt: merged, repository: .init(nameWithOwner: "a/b")
    )
}

private func funnel(opened: [PullRequest], merged: [PullRequest]) -> MergeFunnel {
    MonthSnapshot(
        login: "someone", window: MonthWindow(containing: date(11, 1), calendar: newYork),
        opened: opened, merged: merged, totalContributions: 0, fetchedAt: date(11, 20)
    ).mergeFunnel
}

@Suite struct MonthFunnelTests {
    @Test func splitsWhatWasOpenedThisMonthByWhetherItMerged() {
        let landed = pullRequest(opened: date(11, 2), merged: date(11, 3))
        let waiting = pullRequest(opened: date(11, 2), merged: nil)
        let result = funnel(opened: [landed, waiting, waiting], merged: [landed])
        #expect(result.opened == 3)
        #expect(result.openedAndMerged == 1)
        #expect(result.notMerged == 2)
        #expect(result.mergeRate == 1.0 / 3.0)
    }

    @Test func mergesOfOlderPRsAreCarriedInAndStayOutOfTheRate() {
        let older = pullRequest(opened: date(10, 20), merged: date(11, 2))
        let landed = pullRequest(opened: date(11, 2), merged: date(11, 3))
        let result = funnel(opened: [landed], merged: [older, older, landed])
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
}
