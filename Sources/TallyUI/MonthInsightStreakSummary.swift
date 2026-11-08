import SwiftUI
import TallyCore

/// Activity consistency alongside the recent volume, scoped to this month and the selected metric.
struct MonthInsightStreakSummary: View {
    let snapshot: MonthSnapshot
    let metric: PRMetric
    let now: Date

    var body: some View {
        if let streak = MonthInsightStreak(snapshot: snapshot, metric: metric, at: now) {
            let text = MonthInsightStreakText(streak: streak, metric: metric)
            Text(text.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .help(text.help)
        }
    }
}

struct MonthInsightStreakText {
    let summary: String
    let help: String

    init(streak: MonthInsightStreak, metric: PRMetric) {
        let current = streak.currentDays
        summary = "Streak: \(current.formatted()) \(current == 1 ? "day" : "days") · month best: \(streak.bestDays.formatted())"
        help = "Consecutive local calendar days with at least one PR \(metric.rawValue), within this month only. "
            + "A quiet today keeps yesterday's streak until today ends; activity today extends it. "
            + "At month end, the streak ends on the month's last day. "
            + "Best this month: \(streak.bestDays.formatted()) \(streak.bestDays == 1 ? "day" : "days")."
    }
}
