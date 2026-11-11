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

private func snapshot(_ days: [Int]) -> MonthSnapshot {
    let prs = days.enumerated().map { index, day in
        PullRequest(
            id: "\(index)", title: "Fixture", url: URL(string: "https://example.test/\(index)")!,
            createdAt: date(day), mergedAt: date(day), repository: .init(nameWithOwner: "me/app")
        )
    }
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: date(1), calendar: calendar),
        opened: prs, merged: prs, totalContributions: 0, fetchedAt: date(30)
    )
}

private func text(_ days: [Int], goal: Int = 60, metric: PRMetric = .opened, now: Int) throws -> MonthInsightQuotaDaysText {
    let month = snapshot(days)
    let quotaDays = try #require(MonthInsightQuotaDays(snapshot: month, metric: metric, goal: goal, at: date(now)))
    return MonthInsightQuotaDaysText(quotaDays: quotaDays, metric: metric, goal: goal, window: month.window)
}

@Suite struct MonthInsightQuotaDaysSummaryTests {
    @Test func theSummaryCountsBeatenDaysAgainstJudgedDays() throws {
        #expect(try text([1, 1, 1], now: 2).summary == "Beat the daily quota on 1 of 1 day")
        #expect(try text([1, 1, 1, 3, 3, 3], now: 5).summary == "Beat the daily quota on 2 of 4 days")
        #expect(try text([1, 2], now: 4).summary == "Beat the daily quota on 0 of 3 days")
    }

    @Test func helpNamesTheQuotaWhereItComesFromAndHowTodayCounts() throws {
        for metric in PRMetric.allCases {
            let help = try text([1, 1, 1], goal: 100, metric: metric, now: 3).help
            #expect(help.contains("more than 3.3 PRs \(metric.rawValue)"))
            #expect(help.contains("goal of 100 spread evenly over 30 days"))
            #expect(help.contains("bars are green"))
            #expect(help.contains("today once it beats the quota"))
        }
    }

    @Test func theQuotaLineStretchesTheBarsOnlyWhileTheyKeepHalfTheHeight() {
        // Inside the bars' own scale: the line sits among them and the scale is unchanged.
        #expect(MonthInsightQuotaDaysText.scale(tallest: 6, quota: 2) == (6, 2))
        // A little above the tallest bar: the scale grows to show the line.
        #expect(MonthInsightQuotaDaysText.scale(tallest: 3, quota: 3.3) == (3.3, 3.3))
        #expect(MonthInsightQuotaDaysText.scale(tallest: 3, quota: 6) == (6, 6))
        // Far above: the bars keep their scale and the line is left out.
        #expect(MonthInsightQuotaDaysText.scale(tallest: 6, quota: 33.3) == (6, nil))
        // An empty month still gets a scale, and a line when the quota is small.
        #expect(MonthInsightQuotaDaysText.scale(tallest: 0, quota: 0.5) == (1, 0.5))
        #expect(MonthInsightQuotaDaysText.scale(tallest: 0, quota: 3) == (1, nil))
    }

    @MainActor @Test func theSummaryFitsOneLineWithinThePopoverWidth() throws {
        let month = snapshot(Array(1...30) + Array(1...30))
        let quotaDays = try #require(MonthInsightQuotaDays(snapshot: month, metric: .opened, goal: 30, at: date(30)))
        let view = MonthInsightQuotaDaysSummary(quotaDays: quotaDays, metric: .opened, goal: 30, window: month.window)
        let renderer = ImageRenderer(content: view.frame(width: 288, alignment: .leading))
        let image = try #require(renderer.cgImage)
        #expect(image.height > 0)
        #expect(image.height <= 20)
    }
}
