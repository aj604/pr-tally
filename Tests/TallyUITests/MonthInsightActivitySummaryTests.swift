import SwiftUI
import Testing
import TallyCore
@testable import TallyUI

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!
    return calendar
}()

private func date(_ day: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day))!
}

private func snapshot(recent: Int, previous: Int, metric: PRMetric) -> MonthSnapshot {
    let prs = (0..<(recent + previous)).map { index in
        PullRequest(
            id: "\(index)", title: "A change", url: URL(string: "https://github.com/me/app/pull/1")!,
            createdAt: date(index < previous ? 1 : 8), mergedAt: date(index < previous ? 1 : 8),
            repository: .init(nameWithOwner: "me/app")
        )
    }
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: date(1), calendar: calendar),
        opened: metric == .opened ? prs : [], merged: metric == .merged ? prs : [], totalContributions: 0, fetchedAt: date(15)
    )
}

@Suite struct MonthInsightActivitySummaryTests {
    @Test func theTextNamesTheMetricAndWhetherTheRecentWeekHasMoreFewerOrTheSame() throws {
        for metric in PRMetric.allCases {
            for (recent, previous, expected) in [
                (5, 2, "3 more than previous 7 days"),
                (2, 5, "3 fewer than previous 7 days"),
                (0, 0, "Same as previous 7 days"),
            ] {
                let snapshot = snapshot(recent: recent, previous: previous, metric: metric)
                let activity = try #require(MonthInsightActivity(snapshot: snapshot, metric: metric, at: date(15)))
                let text = MonthInsightActivityText(activity: activity, metric: metric, window: snapshot.window)
                #expect(text.total == "Last 7 full days: \(recent) \(metric.rawValue)")
                #expect(text.comparison == expected)
                #expect(text.help.contains("Nov 8–Nov 14: \(recent) PRs \(metric.rawValue)."))
                #expect(text.help.contains("Nov 1–Nov 7: \(previous) PRs \(metric.rawValue)."))
                #expect(text.help.contains("today is excluded"))
            }
        }
    }

    @Test func aSingleCompletedDayHasAnExactLocalDateAndNoComparison() throws {
        let snapshot = snapshot(recent: 0, previous: 2, metric: .opened)
        let activity = try #require(MonthInsightActivity(snapshot: snapshot, metric: .opened, at: date(2)))
        let text = MonthInsightActivityText(activity: activity, metric: .opened, window: snapshot.window)
        #expect(text.total == "Last 1 full day: 2 opened")
        #expect(text.comparison == nil)
        // Kiritimati's Nov 1 begins on Oct 31 in UTC; labels must follow the snapshot's calendar.
        #expect(text.help.hasPrefix("Nov 1: 2 PRs opened."))
    }

    @MainActor @Test func theSummaryRendersWithinThePopoverWidth() throws {
        let view = MonthInsightActivitySummary(
            snapshot: snapshot(recent: 5, previous: 2, metric: .opened), metric: .opened, now: date(15)
        )
        let renderer = ImageRenderer(content: view.frame(width: 288, alignment: .leading))
        let image = try #require(renderer.cgImage)
        #expect(image.width == 288)
        #expect(image.height > 20)
        #expect(image.height <= 48)
    }
}
