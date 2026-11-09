import Foundation
import TallyCore

/// The day the list's day segment shows and the days either side of it, so a neighbouring day is one click instead of
/// a trip back to the charts. Stepping stops at the first of the month and at today, since no PR is counted on a later
/// day; a month that has ended steps through to its last day. Today is named "Today" and keeps the `.today` scope, so
/// stepping onto it reads the same as opening on it.
struct PullRequestWorkspaceDayStepper: Equatable {
    /// Zero-based day of the month.
    let day: Int
    let title: String
    let scope: PullRequestScope
    let previous: Day?
    let next: Day?

    /// A day one step away, named for the arrow's tooltip.
    struct Day: Equatable {
        let day: Int
        let title: String
    }

    init(day: Int, in window: MonthWindow, at now: Date) {
        let today = window.dayIndex(of: now)
        let last = today ?? window.dayCount - 1
        func name(_ day: Int) -> String { day == today ? "Today" : window.dayTitle(day) }
        let day = min(max(day, 0), last)
        self.day = day
        title = name(day)
        scope = day == today ? .today : .day(day)
        previous = day > 0 ? Day(day: day - 1, title: name(day - 1)) : nil
        next = day < last ? Day(day: day + 1, title: name(day + 1)) : nil
    }

    /// The day the segment starts on: the scope's own day, or else today, or the month's last day once it has ended.
    /// A list that opens on the whole month still has a day to step from when the day segment is picked.
    static func openingDay(for scope: PullRequestScope, in window: MonthWindow, at now: Date) -> Int {
        if case .day(let day) = scope { return day }
        return window.dayIndex(of: now) ?? window.dayCount - 1
    }
}
