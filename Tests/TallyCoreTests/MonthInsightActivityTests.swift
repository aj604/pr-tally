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
    func pr(_ index: Int, day: Int, merged: Bool) -> PullRequest {
        PullRequest(
            id: "\(merged)-\(index)", title: "A change", url: URL(string: "https://github.com/me/app/pull/1")!,
            createdAt: merged ? date(1).addingTimeInterval(-86_400) : date(day, hour: 12),
            mergedAt: merged ? date(day, hour: 12) : nil, repository: .init(nameWithOwner: "me/app")
        )
    }
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: date(1), calendar: calendar),
        opened: days.enumerated().map { pr($0.offset, day: $0.element, merged: false) },
        merged: mergeDays.enumerated().map { pr($0.offset, day: $0.element, merged: true) },
        totalContributions: 0, fetchedAt: date(30)
    )
}

@Suite struct MonthInsightActivityTests {
    @Test func theRecentWeekExcludesTodayAndUsesTheSevenPrecedingCalendarDays() throws {
        let snapshot = snapshot(opened: [1, 7, 8, 8, 14, 15, 15, 16])
        let activity = try #require(MonthInsightActivity(snapshot: snapshot, metric: .opened, at: date(15, hour: 23)))
        #expect(activity.recentDays == 7..<14)
        #expect(activity.recentCount == 3)
        #expect(activity.previousDays == 0..<7)
        #expect(activity.previousCount == 2)
        #expect(activity.change == 1)
    }

    @Test func earlyInTheMonthUsesOnlyAvailableFullDaysWithoutComparingPartialWeeks() throws {
        let snapshot = snapshot(opened: [1, 1, 2, 3])
        let activity = try #require(MonthInsightActivity(snapshot: snapshot, metric: .opened, at: date(3, hour: 12)))
        #expect(activity.recentDays == 0..<2)
        #expect(activity.recentCount == 3)
        #expect(activity.previousDays == nil)
        #expect(activity.previousCount == nil)
        #expect(activity.change == nil)
    }

    @Test func theFirstDayAndDatesBeforeTheMonthHaveNoCompletedDays() {
        let snapshot = snapshot(opened: [1])
        #expect(MonthInsightActivity(snapshot: snapshot, metric: .opened, at: date(1, hour: 23)) == nil)
        #expect(MonthInsightActivity(snapshot: snapshot, metric: .opened, at: date(1).addingTimeInterval(-1)) == nil)
    }

    @Test func comparisonStartsOnlyWhenFourteenFullDaysExist() throws {
        let snapshot = snapshot(opened: [1, 14])
        let before = try #require(MonthInsightActivity(snapshot: snapshot, metric: .opened, at: date(14, hour: 23)))
        #expect(before.recentDays == 6..<13)
        #expect(before.previousCount == nil)
        let after = try #require(MonthInsightActivity(snapshot: snapshot, metric: .opened, at: date(15)))
        #expect(after.previousCount == 1)
        #expect(after.recentCount == 1)
        #expect(after.change == 0)
    }

    @Test func mergedActivityUsesMergeDatesIncludingPRsOpenedBeforeThisMonth() throws {
        let snapshot = snapshot(opened: [8, 8, 14], merged: [1, 2, 8, 15])
        let activity = try #require(MonthInsightActivity(snapshot: snapshot, metric: .merged, at: date(15, hour: 12)))
        #expect(activity.recentCount == 1)
        #expect(activity.previousCount == 2)
        #expect(activity.change == -1)
    }

    @Test func quietWeeksStillShowZeroAndAnUnchangedComparison() throws {
        let activity = try #require(MonthInsightActivity(snapshot: snapshot(opened: []), metric: .opened, at: date(15)))
        #expect(activity.recentCount == 0)
        #expect(activity.previousCount == 0)
        #expect(activity.change == 0)
    }

    @Test func theLocalDayBoundaryAfterDaylightSavingCompletesADayAtMidnight() throws {
        // Nov 1 has 25 hours in New York; a fixed 24-hour offset would still land on Nov 1.
        let snapshot = snapshot(opened: [1, 2])
        let activity = try #require(MonthInsightActivity(snapshot: snapshot, metric: .opened, at: date(2)))
        #expect(activity.recentDays == 0..<1)
        #expect(activity.recentCount == 1)
        #expect(date(2).timeIntervalSince(date(1)) == 25 * 3600)
    }

    @Test func theLastDayIsIncludedOnlyOnceTheMonthEnds() throws {
        let snapshot = snapshot(opened: [16, 17, 23, 24, 30])
        let activity = try #require(MonthInsightActivity(snapshot: snapshot, metric: .opened, at: snapshot.window.end))
        #expect(activity.recentDays == 23..<30)
        #expect(activity.recentCount == 2)
        #expect(activity.previousDays == 16..<23)
        #expect(activity.previousCount == 2)
        #expect(MonthInsightActivity(snapshot: snapshot, metric: .opened, at: snapshot.window.end.addingTimeInterval(86400)) == activity)
    }
}
