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

private func snapshot(_ days: [Int], metric: PRMetric = .opened) -> MonthSnapshot {
    let prs = days.enumerated().map { index, day in
        PullRequest(
            id: "\(index)", title: "Fixture", url: URL(string: "https://example.test/\(index)")!,
            createdAt: date(day), mergedAt: date(day), repository: .init(nameWithOwner: "me/app")
        )
    }
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: date(1), calendar: calendar),
        opened: metric == .opened ? prs : [], merged: metric == .merged ? prs : [], totalContributions: 0, fetchedAt: date(30)
    )
}

@Suite struct MonthInsightStreakSummaryTests {
    @Test func theSummaryShowsCurrentAndBestWithSingularAndPluralDays() throws {
        for (days, now, expected) in [
            ([1], 2, "Streak: 1 day · month best: 1"),
            ([1, 2, 3], 4, "Streak: 3 days · month best: 3"),
            ([1, 2, 3], 5, "Streak: 0 days · month best: 3"),
        ] {
            let streak = try #require(MonthInsightStreak(snapshot: snapshot(days), metric: .opened, at: date(now)))
            #expect(MonthInsightStreakText(streak: streak, metric: .opened).summary == expected)
        }
    }

    @Test func helpNamesTheSelectedMetricAndExplainsCalendarAndMonthBoundaries() throws {
        for metric in PRMetric.allCases {
            let streak = try #require(MonthInsightStreak(snapshot: snapshot([1, 2], metric: metric), metric: metric, at: date(3)))
            let text = MonthInsightStreakText(streak: streak, metric: metric)
            #expect(text.help.contains("at least one PR \(metric.rawValue)"))
            #expect(text.help.contains("local calendar days"))
            #expect(text.help.contains("within this month only"))
            #expect(text.help.contains("quiet today keeps yesterday's streak until today ends"))
            #expect(text.help.contains("month's last day"))
            #expect(text.help.contains("Best this month: 2 days."))
        }
    }

    @MainActor @Test func theSummaryFitsOneLineWithinThePopoverWidth() throws {
        let view = MonthInsightStreakSummary(snapshot: snapshot(Array(1...30)), metric: .opened, now: date(30))
        let renderer = ImageRenderer(content: view.frame(width: 288, alignment: .leading))
        let image = try #require(renderer.cgImage)
        #expect(image.width == 288)
        #expect(image.height > 0)
        #expect(image.height <= 20)
    }

    @MainActor @Test func theQuietMonthDoesNotReserveSummaryHeight() throws {
        let summary = MonthInsightStreakSummary(snapshot: snapshot([]), metric: .opened, now: date(15))
        let renderer = ImageRenderer(content: VStack(spacing: 0) { summary; Color.clear.frame(height: 1) }.frame(width: 288))
        let image = try #require(renderer.cgImage)
        #expect(image.height == 1)
    }
}
