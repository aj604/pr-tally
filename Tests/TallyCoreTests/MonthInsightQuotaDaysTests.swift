import Foundation
import Testing
@testable import TallyCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

/// One PR per entry, opened at noon on that day of November, or opened in October and merged then when `merged`.
private func snapshot(opened days: [Int], merged mergeDays: [Int] = []) -> MonthSnapshot {
    func prs(_ days: [Int], merged: Bool) -> [PullRequest] {
        days.enumerated().map { index, day in
            PullRequest(
                id: "\(merged)-\(index)", title: "Fixture", url: URL(string: "https://example.test/\(index)")!,
                createdAt: merged ? date(10, 20) : date(day: day, hour: 12),
                mergedAt: merged ? date(day: day, hour: 12) : nil, repository: .init(nameWithOwner: "me/app")
            )
        }
    }
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: date(day: 1), calendar: calendar),
        opened: prs(days, merged: false), merged: prs(mergeDays, merged: true), totalContributions: 0,
        fetchedAt: date(day: 30)
    )
}

private func date(day: Int, hour: Int = 0) -> Date { date(11, day, hour: hour) }

/// A goal of 60 over November's 30 days is a quota of 2 a day.
@Suite struct MonthInsightQuotaDaysTests {
    @Test func countsCompletedDaysPastTheQuotaAndNotOnesLevelWithIt() throws {
        let month = snapshot(opened: [1, 1, 1, 2, 2, 3, 3, 3, 3])
        let result = try #require(MonthInsightQuotaDays(snapshot: month, metric: .opened, goal: 60, at: date(day: 5)))
        #expect(result.quota == 2)
        #expect(result.beatenDays == [0, 2])
        #expect(result.beaten == 2)
        #expect(result.days == 4)
    }

    @Test func agreesWithPaceAboutWhetherADayBeatTheQuota() throws {
        let window = MonthWindow(containing: date(day: 1), calendar: calendar)
        let month = snapshot(opened: [1, 2, 2, 3, 3, 3])
        for goal in [1, 29, 30, 31, 45, 59, 60, 61, 89, 90, 91] {
            let result = try #require(MonthInsightQuotaDays(snapshot: month, metric: .opened, goal: goal, at: date(day: 4)))
            let pace = Pace(goal: goal, count: 6, window: window, at: date(day: 4))
            #expect(result.quota == pace.dailyQuota)
            for (day, count) in month.dailyCounts(for: .opened).prefix(3).enumerated() {
                #expect(result.beat(day: day) == pace.beatsDailyQuota(today: count), "goal \(goal), day \(day + 1)")
            }
        }
    }

    @Test func aTodayShortOfTheQuotaIsStillInProgressNotAMiss() throws {
        let short = try #require(
            MonthInsightQuotaDays(snapshot: snapshot(opened: [1, 1, 1, 2]), metric: .opened, goal: 60, at: date(day: 2, hour: 18))
        )
        #expect(short.beatenDays == [0])
        #expect(short.days == 1)
        let beaten = try #require(
            MonthInsightQuotaDays(
                snapshot: snapshot(opened: [1, 1, 1, 2, 2, 2]), metric: .opened, goal: 60, at: date(day: 2, hour: 18)
            )
        )
        #expect(beaten.beatenDays == [0, 1])
        #expect(beaten.days == 2)
    }

    @Test func theFirstDayCountsOnceItBeatsTheQuota() throws {
        let quiet = snapshot(opened: [1, 1])
        #expect(MonthInsightQuotaDays(snapshot: quiet, metric: .opened, goal: 60, at: date(day: 1, hour: 18)) == nil)
        let beaten = try #require(
            MonthInsightQuotaDays(snapshot: snapshot(opened: [1, 1, 1]), metric: .opened, goal: 60, at: date(day: 1, hour: 18))
        )
        #expect(beaten.beaten == 1)
        #expect(beaten.days == 1)
    }

    @Test func afterMonthEndEveryDayIsJudged() throws {
        let month = snapshot(opened: [1, 1, 1, 30, 30, 30])
        let result = try #require(MonthInsightQuotaDays(snapshot: month, metric: .opened, goal: 60, at: date(12, 3)))
        #expect(result.beatenDays == [0, 29])
        #expect(result.days == 30)
    }

    @Test func followsTheSelectedMetric() throws {
        let month = snapshot(opened: [1, 1, 1], merged: [3, 3, 3])
        let opened = try #require(MonthInsightQuotaDays(snapshot: month, metric: .opened, goal: 60, at: date(day: 4)))
        let merged = try #require(MonthInsightQuotaDays(snapshot: month, metric: .merged, goal: 60, at: date(day: 4)))
        #expect(opened.beatenDays == [0])
        #expect(merged.beatenDays == [2])
    }

    @Test func nilForANonpositiveGoalOrBeforeTheMonth() {
        let month = snapshot(opened: [1, 1, 1])
        #expect(MonthInsightQuotaDays(snapshot: month, metric: .opened, goal: 0, at: date(day: 4)) == nil)
        #expect(MonthInsightQuotaDays(snapshot: month, metric: .opened, goal: -5, at: date(day: 4)) == nil)
        #expect(MonthInsightQuotaDays(snapshot: month, metric: .opened, goal: 60, at: date(10, 31)) == nil)
    }
}
