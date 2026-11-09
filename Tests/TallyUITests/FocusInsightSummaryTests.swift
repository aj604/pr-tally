import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ day: Int, hour: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
}

private let now = date(10, hour: 12)

private func pr(
    _ id: String, day: Int, repo: String = "me/app", mergedAfter hours: Double? = nil, state: PullRequest.State? = nil
) -> PullRequest {
    PullRequest(
        id: id, title: "Fixture", url: URL(string: "https://example.test/\(id)")!, createdAt: date(day, hour: 9),
        mergedAt: hours.map { date(day, hour: 9).addingTimeInterval($0 * 3_600) }, repository: .init(nameWithOwner: repo),
        state: state
    )
}

/// Twenty PRs over ten days, two a day on average: four on the 3rd, three of them merged.
private let snapshot: MonthSnapshot = {
    let busy = [
        pr("a", day: 3, mergedAfter: 2, state: .merged), pr("b", day: 3, mergedAfter: 6, state: .merged),
        pr("c", day: 3, repo: "acme/infra", mergedAfter: 50, state: .merged), pr("d", day: 3, state: .closed),
    ]
    let rest = (0..<16).map { pr("r\($0)", day: 4 + $0 % 6, repo: "acme/infra", state: .open) }
    let opened = busy + rest
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: now, calendar: calendar), opened: opened,
        merged: opened.filter { $0.mergedAt != nil }, totalContributions: 0, fetchedAt: now
    )
}()

private func text(_ focus: PullRequestFocus, metric: PRMetric = .opened) -> FocusInsightText? {
    FocusInsightText(snapshot: snapshot, metric: metric, focus: focus, now: now)
}

@Suite struct FocusInsightSummaryTests {
    @Test func theUnfocusedListHasNoInsight() {
        #expect(text(PullRequestFocus()) == nil)
    }

    @Test func aDayComparesWithAnAverageDayAndSaysHowItsPRsStand() throws {
        let text = try #require(text(PullRequestFocus(day: 2)))
        #expect(text.title == "Tue, Nov 3")
        #expect(text.lines == [
            "4 opened · 2× an average day",
            "3 merged in a median 6h · 1 closed",
            "2 repos, most in me/app (3)",
        ])
    }

    @Test func aQuietDaySaysWhatAnAverageDayHas() throws {
        #expect(try #require(text(PullRequestFocus(day: 0))).lines == ["None opened · an average day has 2"])
    }

    @Test func todayIsTitledToday() throws {
        #expect(try #require(text(PullRequestFocus(day: 9))).title == "Today")
    }

    @Test func aRepositoryShowsItsShareOfTheMonthAndNoRepositoryLine() throws {
        let text = try #require(text(PullRequestFocus(repository: "acme/infra")))
        #expect(text.title == "acme/infra")
        #expect(text.lines == ["17 of 20 opened this month · 85%", "1 merged in a median 2.1 days · 16 open"])
    }

    @Test func theOtherMetricIsTheWholeMonthWithItsMergeTime() throws {
        let text = try #require(text(PullRequestFocus(metric: .merged)))
        #expect(text.title == "Merged this month")
        #expect(text.lines == ["3 merged this month", "Median 6h from open to merge", "2 repos, most in me/app (2)"])
    }

    @Test func aFunnelPartIsNamedAndComparedWithItsMetric() throws {
        let text = try #require(text(PullRequestFocus(funnel: .notMerged)))
        #expect(text.title == "Opened, not merged")
        #expect(text.lines.first == "17 of 20 opened this month · 85%")
    }

    @Test func durationsReadInMinutesHoursThenDays() {
        #expect(FocusInsightText.duration(20) == "1m")
        #expect(FocusInsightText.duration(45 * 60) == "45m")
        #expect(FocusInsightText.duration(5 * 3_600) == "5h")
        #expect(FocusInsightText.duration(47 * 3_600) == "47h")
        #expect(FocusInsightText.duration(60 * 3_600) == "2.5 days")
    }
}

@Suite struct FocusInsightCacheTests {
    @Test func statesSurviveTheCacheAndAnOlderFileStillLoads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SnapshotCache(url: url)
        let draft = PullRequest(
            id: "x", title: "Fixture", url: URL(string: "https://example.test/x")!, createdAt: date(3), mergedAt: nil,
            repository: .init(nameWithOwner: "me/app"), state: .open, isDraft: true, reviewDecision: .approved,
            checks: .failure
        )
        cache.save(MonthSnapshot(
            login: "me", window: MonthWindow(containing: now, calendar: calendar), opened: [draft], merged: [],
            totalContributions: 0, fetchedAt: now
        ))
        #expect(cache.load()?.opened == [draft])

        // A file saved before these were stored has none of their keys.
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var opened = try #require(json["opened"] as? [[String: Any]])
        for key in ["state", "isDraft", "reviewDecision", "checks"] { opened[0][key] = nil }
        json["opened"] = opened
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let loaded = try #require(cache.load()?.opened.first)
        #expect(loaded.id == "x")
        #expect(loaded.state == nil && !loaded.isDraft && loaded.reviewDecision == nil && loaded.checks == nil)
    }
}
