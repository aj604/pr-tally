import Foundation
import Testing
import TallyCore
@testable import TallyUI

private let window: MonthWindow = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return MonthWindow(containing: calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12))!, calendar: calendar)
}()

/// Noon on November 16th toward a goal of 1000: a steady pace needs 33.3 a day, and with 450 counted before today,
/// today's share of the 550 left over 15 days is 36.7, so 37.
private func note(before: Int = 450, today: Int) -> TodayNote {
    let noon = window.calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12))!
    return TodayNote(pace: Pace(goal: 1000, count: before + today, window: window, at: noon), today: today)
}

@Suite struct TodayNoteTests {
    @Test func behindPaceADayCanBeatTheQuotaAndStillBeShortOfItsShare() {
        let note = note(today: 35)
        #expect(note.overQuota == 2)
        #expect(note.moreToday == 2)
    }

    @Test func onlyTheQuotaShowsOnceTodayHasItsShare() {
        #expect(note(today: 37).overQuota == 4)
        #expect(note(today: 37).moreToday == nil)
    }

    @Test func onlyWhatIsLeftShowsUntilTodayBeatsTheQuota() {
        #expect(note(today: 20).overQuota == nil)
        #expect(note(today: 20).moreToday == 17)
    }

    @Test func aheadOfPaceTheQuotaIsTheMoreDemandingOfTheTwo() {
        // 520 before today leaves 480 over 15 days, 32 a day: beating the 33.3 quota already covers it.
        let note = note(before: 520, today: 34)
        #expect(note.overQuota == 1)
        #expect(note.moreToday == nil)
    }

    @Test func nothingShowsOnceTheGoalIsHit() {
        #expect(note(before: 990, today: 40).overQuota == nil)
        #expect(note(before: 990, today: 40).moreToday == nil)
    }
}
