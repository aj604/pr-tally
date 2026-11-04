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
