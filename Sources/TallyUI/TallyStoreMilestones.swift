import Foundation
import TallyCore

/// Something worth interrupting the user for.
public struct Milestone: Equatable, Sendable {
    public let title: String
    public let body: String

    /// The goal being reached: `previous` fell short of it and `snapshot` doesn't, in the same month.
    ///
    /// The previous numbers can be the saved ones from before a relaunch, so a goal reached while the app
    /// wasn't running is still noticed. With no previous numbers, from another month or another account, or
    /// already over the goal (a lowered goal, a metric switch), nothing was reached just now.
    static func goalReached(
        from previous: MonthSnapshot?, to snapshot: MonthSnapshot, metric: PRMetric, goal: Int, at now: Date
    ) -> Milestone? {
        guard let previous, previous.login == snapshot.login, snapshot.window.contains(now),
            previous.window.monthKey == snapshot.window.monthKey,
            previous.count(for: metric) < goal, snapshot.count(for: metric) >= goal
        else { return nil }
        let window = snapshot.window
        let month = window.start.formatted(
            Date.FormatStyle(calendar: window.calendar, timeZone: window.calendar.timeZone).month(.wide)
        )
        // `daysRemaining` counts today.
        let spare = window.daysRemaining(at: now) - 1
        let timing = switch spare {
        case ..<1: "on the last day of the month"
        case 1: "with a day to spare"
        default: "with \(spare.formatted()) days to spare"
        }
        let count = snapshot.count(for: metric)
        let verb = metric == .opened ? "opened" : "merged"
        let prs = count == 1 ? "1 PR" : "\(count.formatted()) PRs"
        return Milestone(title: "Goal hit 🎉", body: "\(prs) \(verb) in \(month), \(timing).")
    }
}

extension MonthWindow {
    /// Names the month on the window's own calendar, such as "2026-11". Stable across a change of zone.
    var monthKey: String {
        let parts = calendar.dateComponents([.year, .month], from: start)
        return "\(parts.year!)-\(parts.month!)"
    }
}
