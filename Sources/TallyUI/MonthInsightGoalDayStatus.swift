import SwiftUI
import TallyCore

/// The existing pace status becomes a dated route to the day that reached the current goal.
struct MonthInsightGoalDayStatus: View {
    let snapshot: MonthSnapshot
    let metric: PRMetric
    let pace: Pace
    let now: Date
    var selectDay: (Int) -> Void = { _ in }

    var body: some View {
        Group {
            if pace.status == .goalHit,
                let reached = MonthInsightGoalDay(snapshot: snapshot, metric: metric, goal: pace.goal, at: now) {
                let text = MonthInsightGoalDayText(reached: reached, goal: pace.goal, metric: metric, window: snapshot.window)
                Button { selectDay(reached.day) } label: {
                    Text(text.summary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(text.help)
                .accessibilityLabel(text.help)
            } else {
                Text(pace.statusText)
            }
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(pace.statusColor)
    }
}

struct MonthInsightGoalDayText {
    let summary: String
    let help: String

    init(reached: MonthInsightGoalDay, goal: Int, metric: PRMetric, window: MonthWindow) {
        let date = window.dayTitle(reached.day)
        summary = "Goal hit \(date) 🎉"
        help = "Current goal of \(goal.formatted()) PRs \(metric.rawValue) first reached on \(date). List that day's PRs."
    }
}
