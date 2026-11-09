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
            "3 merged in a median 6h · about the month's 6h",
            "1 closed",
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
        #expect(text.lines == [
            "17 of 20 opened this month · 85%", "1 merged in a median 2.1 days · 8.3× the month's 6h", "16 open",
        ])
    }

    @Test func theOtherMetricIsTheWholeMonthWithItsMergeTime() throws {
        let text = try #require(text(PullRequestFocus(metric: .merged)))
        #expect(text.title == "Merged this month")
        #expect(text.lines == ["3 merged this month", "Merged in a median 6h", "2 repos, most in me/app (2)"])
    }

    @Test func theOtherMetricWithMergesTodayIsDescribedAsTodayLikeTheListItOpens() throws {
        // Two merged today on top of the three merged on the 3rd and 5th, so the list opens on Today.
        let merged = snapshot.merged + [
            pr("t1", day: 10, mergedAfter: 1, state: .merged), pr("t2", day: 10, mergedAfter: 3, state: .merged),
        ]
        let busy = MonthSnapshot(
            login: "me", window: snapshot.window, opened: snapshot.opened, merged: merged, totalContributions: 0,
            fetchedAt: now
        )
        let text = try #require(FocusInsightText(snapshot: busy, metric: .opened, focus: PullRequestFocus(metric: .merged), now: now))
        #expect(text.title == "Merged today")
        #expect(text.lines == ["2 merged · 4× an average day", "Merged in a median 2h · faster than the month's 3h", "All in me/app"])
        #expect(FocusInsightText.otherMetricHelp(snapshot: busy, metric: .opened, now: now) == "List the 2 PRs merged today")
        #expect(FocusInsightText.otherMetricHelp(snapshot: snapshot, metric: .opened, now: now) == "List the 3 PRs merged")
    }

    @Test func aFunnelPartIsNamedAndComparedWithItsMetric() throws {
        let text = try #require(text(PullRequestFocus(funnel: .notMerged)))
        #expect(text.title == "Opened, not merged")
        #expect(text.lines.first == "17 of 20 opened this month · 85%")
    }

    @Test func aSliceSaysHowBigItsPullRequestsRunBesideTheMonths() throws {
        func sized(_ id: String, day: Int, repo: String = "me/app", lines: Int) -> PullRequest {
            PullRequest(
                id: id, title: "Fixture", url: URL(string: "https://example.test/\(id)")!, createdAt: date(day, hour: 9),
                mergedAt: nil, repository: .init(nameWithOwner: repo), additions: lines, deletions: 0
            )
        }
        // The month's median is 50 lines; acme/infra's is 300, me/app's 50 and the 4th's 48.
        let opened = [
            sized("a", day: 3, repo: "acme/infra", lines: 300), sized("b", day: 3, repo: "acme/infra", lines: 300),
            sized("c", day: 4, lines: 46), sized("d", day: 4, lines: 50), sized("e", day: 5, lines: 1),
        ]
        let snapshot = MonthSnapshot(
            login: "me", window: MonthWindow(containing: now, calendar: calendar), opened: opened, merged: [],
            totalContributions: 0, fetchedAt: now
        )
        func text(_ focus: PullRequestFocus) throws -> FocusInsightText {
            try #require(FocusInsightText(snapshot: snapshot, metric: .opened, focus: focus, now: now))
        }
        #expect(try text(PullRequestFocus(repository: "acme/infra")).lines.last == "Median 300 lines changed · 6× the month's 50")
        #expect(try text(PullRequestFocus(day: 3)).lines.contains("Median 48 lines changed · about the month's 50"))
        #expect(try text(PullRequestFocus(day: 4)).lines.contains("Median 1 line changed · under the month's 50"))
        // The whole month is its own size, so it isn't compared with itself.
        #expect(try text(PullRequestFocus(metric: .opened)).lines.contains("Median 50 lines changed"))
    }

    @Test func aSlicesMergeTimeIsComparedWithTheMonthsLikeItsSize() throws {
        // Merged in 2h, 6h and 50h over the month: a median of 6h. me/app's two took 2h and 6h, a median of 4h.
        #expect(try #require(text(PullRequestFocus(repository: "me/app"))).lines.contains("2 merged in a median 4h · faster than the month's 6h"))
        // Within a tenth of the month's either way reads as about the same.
        #expect(try #require(text(PullRequestFocus(day: 2))).lines.contains("3 merged in a median 6h · about the month's 6h"))
        // A slice that is the whole month isn't compared with itself, and where the rest stand stays on the same line.
        let month = try #require(text(PullRequestFocus(metric: .opened)))
        #expect(month.lines.contains("3 merged in a median 6h · 16 open · 1 closed"))
    }

    @Test func mergeTimesThatRoundTheSameReadAsAboutTheMonths() throws {
        // 2.6h beside 3.4h is under the band, but both print as 3h, so "faster than the month's 3h" would contradict itself.
        func line(slice: Double, month: [Double]) throws -> String? {
            let opened = [pr("s", day: 3, repo: "x/x", mergedAfter: slice, state: .merged)]
                + month.enumerated().map { pr("m\($0.offset)", day: 4, mergedAfter: $0.element, state: .merged) }
            let snapshot = MonthSnapshot(
                login: "me", window: MonthWindow(containing: now, calendar: calendar), opened: opened,
                merged: opened, totalContributions: 0, fetchedAt: now
            )
            let text = try #require(FocusInsightText(snapshot: snapshot, metric: .opened, focus: PullRequestFocus(repository: "x/x"), now: now))
            return text.lines.first { $0.contains("merged in") }
        }
        #expect(try line(slice: 2.6, month: [3.4, 5]) == "1 merged in a median 3h · about the month's 3h")
        #expect(try line(slice: 3.4, month: [2.6, 1]) == "1 merged in a median 3h · about the month's 3h")
    }

    @Test func sizesThatRoundTheSameReadAsAboutTheMonths() throws {
        // Small sizes rarely fall within a tenth of each other, so "1.1× the month's 4" would contradict itself.
        func line(slice: [Int], month: [Int]) throws -> String? {
            func sized(_ id: String, repo: String, lines: Int) -> PullRequest {
                PullRequest(
                    id: id, title: "Fixture", url: URL(string: "https://example.test/\(id)")!, createdAt: date(3, hour: 9),
                    mergedAt: nil, repository: .init(nameWithOwner: repo), additions: lines, deletions: 0
                )
            }
            let opened = slice.enumerated().map { sized("s\($0.offset)", repo: "x/x", lines: $0.element) }
                + month.enumerated().map { sized("m\($0.offset)", repo: "me/app", lines: $0.element) }
            let snapshot = MonthSnapshot(
                login: "me", window: MonthWindow(containing: now, calendar: calendar), opened: opened, merged: [],
                totalContributions: 0, fetchedAt: now
            )
            let text = try #require(FocusInsightText(snapshot: snapshot, metric: .opened, focus: PullRequestFocus(repository: "x/x"), now: now))
            return text.lines.first { $0.contains("changed") }
        }
        // 2.5 lines beside the month's 3 (2, 3, 3, 3, 4, 4) is under the band, but prints as 3.
        #expect(try line(slice: [2, 3], month: [3, 3, 4, 4]) == "Median 3 lines changed · about the month's 3")
        // 4 beside the month's 3.5 (3, 3, 3, 4, 4, 4) is over it, but both print as 4.
        #expect(try line(slice: [4, 4], month: [3, 3, 3, 4]) == "Median 4 lines changed · about the month's 4")
        // Sizes that print differently are still compared.
        #expect(try line(slice: [2, 2], month: [3, 3, 4, 4]) == "Median 2 lines changed · under the month's 3")
    }

    @Test func aFoldedHeadingKeepsItsFirstLineAndSaysHowManyMoreItHides() throws {
        let text = try #require(text(PullRequestFocus(day: 2)))
        #expect(text.shownLines(expanded: false) == ["4 opened · 2× an average day"])
        #expect(text.disclosure(expanded: false) == "3 more")
        #expect(text.shownLines(expanded: true) == text.lines)
        #expect(text.disclosure(expanded: true) == "Less")
    }

    @Test func aOneLineHeadingHasNothingToFold() throws {
        let text = try #require(text(PullRequestFocus(day: 0)))
        #expect(text.shownLines(expanded: false) == ["None opened · an average day has 2"])
        #expect(text.disclosure(expanded: false) == nil)
        #expect(text.disclosure(expanded: true) == nil)
    }

    @Test func aSliceWithoutSizesSaysNothingAboutSize() throws {
        #expect(try #require(text(PullRequestFocus(repository: "acme/infra"))).lines.allSatisfy { !$0.contains("lines") })
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
    @Test func statesAndSizesSurviveTheCacheAndAnOlderFileStillLoads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SnapshotCache(url: url)
        let draft = PullRequest(
            id: "x", title: "Fixture", url: URL(string: "https://example.test/x")!, createdAt: date(3), mergedAt: nil,
            repository: .init(nameWithOwner: "me/app"), state: .open, isDraft: true, reviewDecision: .approved,
            checks: .failure, additions: 12, deletions: 3
        )
        cache.save(MonthSnapshot(
            login: "me", window: MonthWindow(containing: now, calendar: calendar), opened: [draft], merged: [],
            totalContributions: 0, fetchedAt: now
        ))
        #expect(cache.load()?.opened == [draft])

        // A file saved before these were stored has none of their keys.
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var opened = try #require(json["opened"] as? [[String: Any]])
        for key in ["state", "isDraft", "reviewDecision", "checks", "additions", "deletions"] { opened[0][key] = nil }
        json["opened"] = opened
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let loaded = try #require(cache.load()?.opened.first)
        #expect(loaded.id == "x")
        #expect(loaded.state == nil && !loaded.isDraft && loaded.reviewDecision == nil && loaded.checks == nil)
        #expect(loaded.additions == nil && loaded.deletions == nil)
    }
}
