import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ day: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day))!
}

/// A month whose opened PRs are `merged` merges, then `open` still open, then `closed` closed, then `unknown` from a
/// snapshot saved before states were fetched.
private func funnel(merged: Int = 0, open: Int = 0, closed: Int = 0, unknown: Int = 0) -> MergeFunnel {
    let states: [(Date?, PullRequest.State?)] = Array(repeating: (date(3), .merged), count: merged)
        + Array(repeating: (nil, .open), count: open)
        + Array(repeating: (nil, .closed), count: closed)
        + Array(repeating: (nil, nil), count: unknown)
    let prs = states.enumerated().map { index, entry in
        PullRequest(
            id: "\(index)", title: "Fixture", url: URL(string: "https://example.test/\(index)")!,
            createdAt: date(2), mergedAt: entry.0, repository: .init(nameWithOwner: "me/app"), state: entry.1
        )
    }
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: date(1), calendar: calendar),
        opened: prs, merged: prs.filter { $0.mergedAt != nil }, totalContributions: 0, fetchedAt: date(10)
    ).mergeFunnel
}

@Suite struct MonthFunnelSummaryTests {
    @Test func theLineSaysHowManyCanStillMergeAndHowManyClosed() {
        #expect(MergeFunnelText(funnel: funnel(merged: 12, open: 30, closed: 3)).split == "30 still open · 3 closed without merging")
        #expect(MergeFunnelText(funnel: funnel(merged: 1, open: 1_200)).split == "1,200 still open")
        #expect(MergeFunnelText(funnel: funnel(merged: 4, closed: 2)).split == "2 closed without merging")
    }

    @Test func theLighterSegmentReachesPastMergedToCoverWhatIsStillOpen() {
        #expect(MergeFunnelText(funnel: funnel(merged: 1, open: 2, closed: 1)).reach == 0.75)
        #expect(MergeFunnelText(funnel: funnel(merged: 1, closed: 3)).reach == 0.25)
    }

    @Test func theHelpNamesAllThreeOnceTheStatesAreKnown() {
        #expect(
            MergeFunnelText(funnel: funnel(merged: 12, open: 30, closed: 3)).help
                == "12 merged, 30 still open, 3 closed without merging"
        )
    }

    @Test func anUnknownStateKeepsTheOldWordingRatherThanGuess() {
        let text = MergeFunnelText(funnel: funnel(merged: 1, open: 2, unknown: 1))
        #expect(text.split == nil)
        #expect(text.reach == nil)
        #expect(text.help == "3 not merged, either still open or closed")
    }

    @Test func nothingUnmergedHasNoLine() {
        let text = MergeFunnelText(funnel: funnel(merged: 3))
        #expect(text.split == nil)
        #expect(text.reach == nil)
    }
}
