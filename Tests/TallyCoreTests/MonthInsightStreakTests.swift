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

private func snapshot(opened days: [Int], merged mergeDays: [Int] = []) -> MonthSnapshot {
    func prs(_ days: [Int], merged: Bool) -> [PullRequest] {
        days.enumerated().map { index, day in
            PullRequest(
                id: "\(merged)-\(index)", title: "Fixture", url: URL(string: "https://example.test/\(index)")!,
                createdAt: merged ? date(1).addingTimeInterval(-3600) : date(day),
                mergedAt: merged ? date(day) : nil, repository: .init(nameWithOwner: "me/app")
            )
        }
    }
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: date(1), calendar: calendar),
        opened: prs(days, merged: false), merged: prs(mergeDays, merged: true), totalContributions: 0, fetchedAt: date(30)
    )
}

@Suite struct MonthInsightStreakTests {
    @Test func equalTotalsRevealSustainedActivityVersusABurst() throws {
        let sustained = try #require(MonthInsightStreak(snapshot: snapshot(opened: [1, 2, 3]), metric: .opened, at: date(4)))
        let burst = try #require(MonthInsightStreak(snapshot: snapshot(opened: [3, 3, 3]), metric: .opened, at: date(4)))
        #expect(sustained.currentDays == 3)
        #expect(sustained.bestDays == 3)
        #expect(burst.currentDays == 1)
        #expect(burst.bestDays == 1)
    }

    @Test func quietTodayPreservesYesterdayUntilALocalDayCompletes() throws {
        let snapshot = snapshot(opened: [1, 2, 3])
        let midnight = try #require(MonthInsightStreak(snapshot: snapshot, metric: .opened, at: date(4)))
        let lateToday = try #require(MonthInsightStreak(snapshot: snapshot, metric: .opened, at: date(4, hour: 23)))
        let tomorrow = try #require(MonthInsightStreak(snapshot: snapshot, metric: .opened, at: date(5)))
        #expect(midnight.currentDays == 3)
        #expect(lateToday == midnight)
        #expect(tomorrow.currentDays == 0)
        #expect(tomorrow.bestDays == 3)
    }

    @Test func activityTodayExtendsTheRunAndCanSetANewBest() throws {
        let streak = try #require(MonthInsightStreak(snapshot: snapshot(opened: [1, 2, 3, 4, 4]), metric: .opened, at: date(4, hour: 12)))
        #expect(streak.currentDays == 4)
        #expect(streak.bestDays == 4)
    }

    @Test func completedGapsBreakTheRunButKeepTheEarlierBest() throws {
        let streak = try #require(MonthInsightStreak(snapshot: snapshot(opened: [1, 2, 3, 5, 6]), metric: .opened, at: date(7)))
        #expect(streak.currentDays == 2)
        #expect(streak.bestDays == 3)
    }

    @Test func futureDaysCannotCreateOrExtendEitherStreak() throws {
        let fixture = snapshot(opened: [1, 2, 4, 5, 6, 7])
        let streak = try #require(MonthInsightStreak(snapshot: fixture, metric: .opened, at: date(3)))
        #expect(streak.currentDays == 2)
        #expect(streak.bestDays == 2)
        #expect(MonthInsightStreak(snapshot: snapshot(opened: [4, 5]), metric: .opened, at: date(3)) == nil)
    }

    @Test func mergedStreakUsesMergeDatesRatherThanOpeningDates() throws {
        let snapshot = snapshot(opened: [1, 2, 3, 4], merged: [2, 3, 5])
        let opened = try #require(MonthInsightStreak(snapshot: snapshot, metric: .opened, at: date(5)))
        let merged = try #require(MonthInsightStreak(snapshot: snapshot, metric: .merged, at: date(5)))
        #expect(opened.currentDays == 4)
        #expect(opened.bestDays == 4)
        #expect(merged.currentDays == 1)
        #expect(merged.bestDays == 2)
    }

    @Test func aQuietMonthAndDatesBeforeTheMonthHaveNoStreakSummary() {
        #expect(MonthInsightStreak(snapshot: snapshot(opened: []), metric: .opened, at: date(15)) == nil)
        #expect(MonthInsightStreak(snapshot: snapshot(opened: [1, 2]), metric: .opened, at: date(1).addingTimeInterval(-1)) == nil)
    }

    @Test func theFirstDayCanStartAStreakWithoutBorrowingFromThePreviousMonth() throws {
        let streak = try #require(MonthInsightStreak(snapshot: snapshot(opened: [0, 1]), metric: .opened, at: date(1, hour: 12)))
        #expect(streak.currentDays == 1)
        #expect(streak.bestDays == 1)
    }

    @Test func localCalendarDaysStayConsecutiveAcrossDaylightSaving() throws {
        #expect(date(2).timeIntervalSince(date(1)) == 25 * 3600)
        let streak = try #require(MonthInsightStreak(snapshot: snapshot(opened: [1, 2]), metric: .opened, at: date(3)))
        #expect(streak.currentDays == 2)
        #expect(streak.bestDays == 2)
    }

    @Test func monthEndFinalizesAQuietLastDayInsteadOfPreservingYesterday() throws {
        let snapshot = snapshot(opened: [28, 29])
        let lastDay = try #require(MonthInsightStreak(snapshot: snapshot, metric: .opened, at: date(30, hour: 23)))
        let ended = try #require(MonthInsightStreak(snapshot: snapshot, metric: .opened, at: snapshot.window.end))
        #expect(lastDay.currentDays == 2)
        #expect(ended.currentDays == 0)
        #expect(ended.bestDays == 2)
        #expect(MonthInsightStreak(snapshot: snapshot, metric: .opened, at: snapshot.window.end.addingTimeInterval(86400)) == ended)
    }

    @Test func anActiveLastDayRemainsTheFinalStreakAfterMonthEnd() throws {
        let snapshot = snapshot(opened: [28, 29, 30])
        let ended = try #require(MonthInsightStreak(snapshot: snapshot, metric: .opened, at: snapshot.window.end))
        #expect(ended.currentDays == 3)
        #expect(ended.bestDays == 3)
    }
}
