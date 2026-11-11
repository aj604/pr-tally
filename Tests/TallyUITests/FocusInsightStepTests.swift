import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ day: Int, month: Int = 11) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9))!
}

private let now = date(10)

private func pr(_ id: String, repo: String, opened: Date = date(3), merged: Date? = nil) -> PullRequest {
    PullRequest(
        id: id, title: "Fixture", url: URL(string: "https://example.test/\(id)")!, createdAt: opened, mergedAt: merged,
        repository: .init(nameWithOwner: repo)
    )
}

/// Opened this month: three in acme/infra, two in me/app, one each in four more, one merged: six repositories, past
/// the five the summary shows. Merged
/// this month besides: one opened in October, in me/web, the only repository with merges and no opens.
private func snapshot(carriedIn: Bool = true) -> MonthSnapshot {
    let opened = [
        pr("i1", repo: "acme/infra"), pr("i2", repo: "acme/infra"), pr("i3", repo: "acme/infra", merged: date(4)),
        pr("a1", repo: "me/app"), pr("a2", repo: "me/app"), pr("d1", repo: "me/dotfiles"), pr("n1", repo: "me/notes"),
        pr("s1", repo: "me/site"), pr("z1", repo: "zz/tools"),
    ]
    let october = carriedIn ? [pr("w1", repo: "me/web", opened: date(20, month: 10), merged: date(5))] : []
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: now, calendar: calendar), opened: opened,
        merged: opened.filter { $0.mergedAt != nil } + october, totalContributions: 0, fetchedAt: now
    )
}

private func step(_ focus: PullRequestFocus, metric: PRMetric = .opened, carriedIn: Bool = true) -> FocusInsightStep? {
    FocusInsightStep(snapshot: snapshot(carriedIn: carriedIn), metric: metric, focus: focus)
}

@Suite struct FocusInsightStepTests {
    @Test func aRepositoryStepsThroughEveryRepositoryInTheTopReposOrder() throws {
        let middle = try #require(step(PullRequestFocus(repository: "me/app")))
        #expect(middle.previous == .init(focus: PullRequestFocus(repository: "acme/infra"), title: "acme/infra"))
        #expect(middle.next == .init(focus: PullRequestFocus(repository: "me/dotfiles"), title: "me/dotfiles"))
        #expect(middle.position == "2 of 6")
        #expect(middle.kind == "repository")

        // Past the five the summary shows, and stopping at the ends rather than wrapping round.
        let last = try #require(step(PullRequestFocus(repository: "zz/tools")))
        #expect(last.previous?.title == "me/site")
        #expect(last.next == nil)
        #expect(last.position == "6 of 6")
        #expect(step(PullRequestFocus(repository: "acme/infra"))?.previous == nil)
    }

    @Test func aRepositoryStepsThroughTheRepositoriesOfTheCountItLists() throws {
        // Merged this month: one each in acme/infra and me/web, so the opened-only repositories aren't neighbors.
        let merged = try #require(step(PullRequestFocus(repository: "acme/infra", metric: .merged)))
        #expect(merged.next == .init(focus: PullRequestFocus(repository: "me/web", metric: .merged), title: "me/web"))
        #expect(merged.position == "1 of 2")
        #expect(step(PullRequestFocus(repository: "me/web"), metric: .merged)?.previous?.focus
            == PullRequestFocus(repository: "acme/infra"))
    }

    @Test func aFunnelPartStepsToTheOtherPart() throws {
        let notMerged = try #require(step(PullRequestFocus(funnel: .notMerged)))
        #expect(notMerged.previous == nil)
        #expect(notMerged.next == .init(focus: PullRequestFocus(funnel: .carriedIn), title: "Opened before Nov"))
        #expect(notMerged.position == "1 of 2")
        let carriedIn = try #require(step(PullRequestFocus(funnel: .carriedIn)))
        #expect(carriedIn.previous == .init(focus: PullRequestFocus(funnel: .notMerged), title: "Opened, not merged"))
        #expect(carriedIn.next == nil)
    }

    @Test func aSliceWithNoNeighborWithPRsDoesNotStep() {
        #expect(step(PullRequestFocus(funnel: .notMerged), carriedIn: false) == nil)
        #expect(step(PullRequestFocus(repository: "acme/infra"), metric: .merged, carriedIn: false) == nil)
        #expect(step(PullRequestFocus(repository: "gone/repo")) == nil)
    }

    @Test func daysAndTheOtherMetricDoNotStepHere() {
        // Stepping days is the list's own, so a slice naming one is left to it, even with a repository too.
        #expect(step(PullRequestFocus(day: 2)) == nil)
        #expect(step(PullRequestFocus(day: 2, repository: "me/app")) == nil)
        #expect(step(PullRequestFocus(metric: .merged)) == nil)
        #expect(step(PullRequestFocus()) == nil)
    }
}
