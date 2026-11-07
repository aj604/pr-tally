import Foundation
import Testing
@testable import TallyCore

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
    newYork.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

@Suite struct MonthWindowTests {
    @Test func spansTheLocalCalendarMonth() {
        let window = MonthWindow(containing: date(11, 4, hour: 12), calendar: newYork)
        #expect(window.start == date(11, 1))
        #expect(window.end == date(12, 1))
        #expect(window.dayCount == 30)
    }

    @Test func dayIndexHandlesTheDaylightSavingChange() {
        // US clocks fall back on 2026-11-01, making that day 25 hours long.
        let window = MonthWindow(containing: date(11, 1), calendar: newYork)
        #expect(window.dayIndex(of: date(11, 1, hour: 23)) == 0)
        #expect(window.dayIndex(of: date(11, 2)) == 1)
        #expect(window.dayIndex(of: date(11, 30, hour: 23)) == 29)
        #expect(window.dayIndex(of: date(12, 1)) == nil)
        #expect(window.dayIndex(of: date(10, 31, hour: 23)) == nil)
    }

    @Test func daysRemainingCountsToday() {
        let window = MonthWindow(containing: date(11, 1), calendar: newYork)
        #expect(window.daysRemaining(at: date(11, 1)) == 30)
        #expect(window.daysRemaining(at: date(11, 30, hour: 23)) == 1)
        #expect(window.daysRemaining(at: date(12, 1)) == 0)
    }
}

@Suite struct PaceTests {
    private let window = MonthWindow(containing: date(11, 1), calendar: newYork)

    @Test func reportsBehindPaceAndWhatItTakesToCatchUp() {
        let pace = Pace(goal: 1000, count: 100, window: window, at: date(11, 16))
        #expect(pace.status == .behind)
        #expect(pace.expected > 490 && pace.expected < 510)
        #expect(pace.delta < 0)
        #expect(pace.remaining == 900)
        #expect(pace.daysRemaining == 15)
        #expect(pace.neededPerDay == 60)
        #expect(pace.projected > 190 && pace.projected < 210)
    }

    @Test func reportsAheadOfPace() {
        let pace = Pace(goal: 1000, count: 800, window: window, at: date(11, 16))
        #expect(pace.status == .ahead)
        #expect(pace.delta > 0)
    }

    @Test func countsPRsOverTodaysQuotaEvenWhenBehindPace() {
        let pace = Pace(goal: 900, count: 100, window: window, at: date(11, 16))
        #expect(pace.status == .behind)
        #expect(pace.dailyQuota == 30)
        #expect(pace.quotaSurplus(today: 35) == 5)
    }

    @Test func meetingTheQuotaExactlyIsNotAheadOfIt() {
        let pace = Pace(goal: 900, count: 100, window: window, at: date(11, 16))
        #expect(pace.quotaSurplus(today: 30) == 0)
        #expect(pace.quotaSurplus(today: 12) == 0)
    }

    @Test func aFractionalQuotaIsBeatenByTheNextWholePR() {
        let pace = Pace(goal: 1000, count: 100, window: window, at: date(11, 16))
        #expect(pace.quotaSurplus(today: 33) == 0)
        #expect(pace.quotaSurplus(today: 34) == 1)
    }

    @Test func noQuotaSurplusOnceTheGoalIsHit() {
        let pace = Pace(goal: 900, count: 950, window: window, at: date(11, 16))
        #expect(pace.quotaSurplus(today: 50) == 0)
    }

    @Test func beatingTheDailyQuotaMeansGoingPastItNotMeetingIt() {
        let pace = Pace(goal: 900, count: 100, window: window, at: date(11, 16))
        #expect(!pace.beatsDailyQuota(today: 29))
        #expect(!pace.beatsDailyQuota(today: 30))
        #expect(pace.beatsDailyQuota(today: 31))
    }

    @Test func aGoodDayStillBeatsTheQuotaAfterTheGoalIsHit() {
        let pace = Pace(goal: 900, count: 950, window: window, at: date(11, 16))
        #expect(pace.beatsDailyQuota(today: 31))
        #expect(!pace.beatsDailyQuota(today: 0))
    }

    @Test func todaysNeedHoldsSteadyAsTodaysPRsLand() {
        // 450 counted before today, with 15 days left counting today: 30 a day, however many land today.
        let morning = Pace(goal: 900, count: 450, window: window, at: date(11, 16, hour: 1))
        let evening = Pace(goal: 900, count: 470, window: window, at: date(11, 16, hour: 23))
        #expect(morning.neededPerDay(today: 0) == 30)
        #expect(evening.neededPerDay(today: 20) == 30)
        #expect(evening.neededPerDay < 30)
    }

    @Test func meetingTodaysNeedLeavesTomorrowsTheSame() {
        let lateToday = Pace(goal: 900, count: 480, window: window, at: date(11, 16, hour: 23))
        let tomorrow = Pace(goal: 900, count: 480, window: window, at: date(11, 17, hour: 1))
        #expect(lateToday.neededPerDay(today: 30) == tomorrow.neededPerDay(today: 0))
        // The rate that counts today's PRs as done jumps at midnight with nothing having changed.
        #expect(lateToday.neededPerDay != tomorrow.neededPerDay)
    }

    @Test func leftTodayIsTheRestOfTodaysShareInWholePRs() {
        // 1000 - 450 = 550 over 15 days is 36.7 a day, so 37 today.
        func pace(today: Int) -> Pace { Pace(goal: 1000, count: 450 + today, window: window, at: date(11, 16, hour: 12)) }
        #expect(pace(today: 20).leftToday(today: 20) == 17)
        #expect(pace(today: 36).leftToday(today: 36) == 1)
        #expect(Pace(goal: 1000, count: 487, window: window, at: date(11, 16, hour: 12)).leftToday(today: 37) == 0)
        #expect(Pace(goal: 1000, count: 500, window: window, at: date(11, 16, hour: 12)).leftToday(today: 50) == 0)
        // 560 over 15 days is 37.3 a day: 37 falls short of it, so one more is left.
        #expect(Pace(goal: 1000, count: 477, window: window, at: date(11, 16, hour: 12)).leftToday(today: 37) == 1)
    }

    @Test func nothingIsLeftTodayOnceTheGoalIsHit() {
        let pace = Pace(goal: 900, count: 905, window: window, at: date(11, 16, hour: 12))
        #expect(pace.neededPerDay(today: 10) == 0)
        #expect(pace.leftToday(today: 10) == 0)
        #expect(Pace(goal: 900, count: 700, window: window, at: date(12, 1)).neededPerDay(today: 0) == 0)
    }

    @Test func goalHitWinsAndNothingRemains() {
        let pace = Pace(goal: 1000, count: 1200, window: window, at: date(11, 2))
        #expect(pace.status == .goalHit)
        #expect(pace.remaining == 0)
        #expect(pace.neededPerDay == 0)
        #expect(pace.fraction == 1)
    }

    @Test func projectionStaysSaneInTheFirstMinutesOfTheMonth() {
        let pace = Pace(goal: 1000, count: 5, window: window, at: date(11, 1).addingTimeInterval(60))
        #expect(pace.projected == 150)
    }

    @Test func survivesTheEndOfTheMonthAndAZeroGoal() {
        let ended = Pace(goal: 1000, count: 900, window: window, at: date(12, 1))
        #expect(ended.neededPerDay == 0)
        #expect(ended.projected == 900)
        #expect(Pace(goal: 0, count: 5, window: window, at: date(11, 2)).fraction == 0)
    }
}
