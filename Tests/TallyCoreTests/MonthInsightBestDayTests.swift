import Foundation
import Testing
@testable import TallyCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ day: Int, hour: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
}

private func snapshot(opened: [Int] = [], merged: [Int] = []) -> MonthSnapshot {
    func prs(_ days: [Int], merged: Bool) -> [PullRequest] {
        days.enumerated().map { index, day in
            PullRequest(
                id: "\(merged)-\(index)", title: "Fixture", url: URL(string: "https://example.test/\(index)")!,
                createdAt: merged ? date(0) : date(day), mergedAt: merged ? date(day) : nil,
                repository: .init(nameWithOwner: "me/app")
            )
        }
    }
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: date(1), calendar: calendar),
        opened: prs(opened, merged: false), merged: prs(merged, merged: true), totalContributions: 0, fetchedAt: date(30)
    )
}

@Suite struct MonthInsightBestDayTests {
    @Test func findsTheBusiestDayRatherThanTheLatestActiveDay() throws {
        let best = try #require(MonthInsightBestDay(snapshot: snapshot(opened: [1, 2, 2, 2, 3]), metric: .opened, at: date(4)))
        #expect(best.day == 1)
        #expect(best.count == 3)
        #expect(best.tiedDays == 1)
    }

    @Test func tiesChooseTheMostRecentDayAndReportAllTiedDays() throws {
        let best = try #require(MonthInsightBestDay(snapshot: snapshot(opened: [1, 1, 3, 3, 5, 5]), metric: .opened, at: date(6)))
        #expect(best.day == 4)
        #expect(best.count == 2)
        #expect(best.tiedDays == 3)
    }

    @Test func todayCanBecomeTheBestDayWhileFutureCalendarDaysAreExcluded() throws {
        let best = try #require(MonthInsightBestDay(snapshot: snapshot(opened: [1, 2, 2, 3, 3, 3]), metric: .opened, at: date(2, hour: 12)))
        #expect(best.day == 1)
        #expect(best.count == 2)
        #expect(best.tiedDays == 1)
    }

    @Test func quietAndFutureOnlyMonthsHaveNoBestDay() {
        #expect(MonthInsightBestDay(snapshot: snapshot(), metric: .opened, at: date(15)) == nil)
        #expect(MonthInsightBestDay(snapshot: snapshot(opened: [10]), metric: .opened, at: date(9)) == nil)
        #expect(MonthInsightBestDay(snapshot: snapshot(opened: [1]), metric: .opened, at: date(0, hour: 23)) == nil)
    }

    @Test func theSelectedMetricUsesItsOwnEventDates() throws {
        let fixture = snapshot(opened: [1, 1, 1], merged: [2, 2, 3])
        let opened = try #require(MonthInsightBestDay(snapshot: fixture, metric: .opened, at: date(4)))
        let merged = try #require(MonthInsightBestDay(snapshot: fixture, metric: .merged, at: date(4)))
        #expect(opened.day == 0)
        #expect(opened.count == 3)
        #expect(merged.day == 1)
        #expect(merged.count == 2)
    }

    @Test func localDaysAcrossDaylightSavingKeepTheirOwnCounts() throws {
        let dates = [date(1, hour: 0), date(1, hour: 23), date(2)]
        let prs = dates.enumerated().map { index, date in
            PullRequest(
                id: "\(index)", title: "Fixture", url: URL(string: "https://example.test/\(index)")!,
                createdAt: date, mergedAt: nil, repository: .init(nameWithOwner: "me/app")
            )
        }
        let fixture = MonthSnapshot(
            login: "me", window: MonthWindow(containing: date(1), calendar: calendar),
            opened: prs, merged: [], totalContributions: 0, fetchedAt: date(3)
        )
        #expect(date(2).timeIntervalSince(date(1)) == 25 * 3600)
        let best = try #require(MonthInsightBestDay(snapshot: fixture, metric: .opened, at: date(3)))
        #expect(best.day == 0)
        #expect(best.count == 2)
    }

    @Test func monthEndIncludesTheLastDayAndIgnoresAdjacentMonths() throws {
        let fixture = snapshot(opened: [0, 0, 0, 30, 30, 31, 31, 31])
        let best = try #require(MonthInsightBestDay(snapshot: fixture, metric: .opened, at: fixture.window.end))
        #expect(best.day == 29)
        #expect(best.count == 2)
        #expect(MonthInsightBestDay(snapshot: fixture, metric: .opened, at: date(32)) == best)
    }

    @Test func theFirstDayCanBeTheBestWithoutACompletedDay() throws {
        let best = try #require(MonthInsightBestDay(snapshot: snapshot(opened: [1]), metric: .opened, at: date(1, hour: 12)))
        #expect(best.day == 0)
        #expect(best.count == 1)
        #expect(best.tiedDays == 1)
    }
}
