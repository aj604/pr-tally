import Foundation
import TallyCore

/// What hovering over the menu bar item says: the numbers the ring and its one number stand for, which the menu bar
/// has no room to show, and why they've faded when they have. Every figure and message is one the popover shows too,
/// worded the same way.
struct MenuBarTooltip: Equatable {
    let lines: [String]

    var text: String { lines.joined(separator: "\n") }

    /// `goalDay` is the day the goal was first reached, when it has been. Without numbers for this month there's only
    /// `lastMonth`, where an ended month stood, if anything. `problem` is why the numbers stopped updating, and
    /// `updated` says when they were fetched and what the next refresh is waiting on.
    init(
        pace: Pace?, today: Int, metric: PRMetric, window: MonthWindow?, goalDay: Int?, lastMonth: String?,
        problem: String? = nil, updated: String?
    ) {
        // Above the update time, as in the popover.
        let footer = [problem, updated].compactMap { $0 }
        guard let pace, let window else {
            lines = [lastMonth ?? "No numbers for this month yet"] + footer
            return
        }
        let month = window.start.formatted(
            Date.FormatStyle(calendar: window.calendar, timeZone: window.calendar.timeZone).month(.wide)
        )
        let progress = "\(pace.count.formatted()) of \(pace.goal.formatted()) \(metric.noun) in \(month)"

        let status: String
        if pace.status == .goalHit {
            status = goalDay.map { "Goal hit \(window.dayTitle($0)) 🎉" } ?? pace.statusText
        } else {
            let days = pace.daysRemaining == 1 ? "1 day left" : "\(pace.daysRemaining.formatted()) days left"
            status = "\(pace.statusText) · \(days)"
        }

        // Explains a green number in the Today display, and what today still needs either way.
        var todayLine = "\(today.formatted()) today"
        var notes: [String] = []
        if pace.beatsDailyQuota(today: today) {
            notes.append("over the daily quota of \(pace.dailyQuota.formatted(.number.precision(.fractionLength(0...1))))")
        }
        let more = pace.leftToday(today: today)
        if more > 0 { notes.append("\(more.formatted()) more for today's share") }
        if !notes.isEmpty { todayLine += ", " + notes.joined(separator: "; ") }

        lines = [progress, status, todayLine] + footer
    }
}

extension TallyStore {
    /// The menu bar item's hover text, for whichever number the menu bar shows.
    public func menuBarTooltip(at now: Date = Date()) -> String {
        let snapshot = currentSnapshot(at: now)
        let pace = pace(at: now)
        let goalDay = snapshot.flatMap { MonthInsightGoalDay(snapshot: $0, metric: metric, goal: goal, at: now)?.day }
        // Only once the menu bar has faded: a failure brief enough to leave it alone isn't news on hover either.
        let problem = menuBarIsStale ? errorMessage : nil
        return MenuBarTooltip(
            pace: pace, today: snapshot?.todayCount(for: metric, at: now) ?? 0, metric: metric,
            window: snapshot?.window, goalDay: goalDay, lastMonth: lastMonthSummary(at: now), problem: problem,
            updated: updatedText(at: now)
        ).text
    }
}
