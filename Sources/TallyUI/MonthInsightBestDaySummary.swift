import SwiftUI
import TallyCore

/// A direct route from the month's busiest day to the pull requests behind its count.
struct MonthInsightBestDaySummary: View {
    let snapshot: MonthSnapshot
    let metric: PRMetric
    let now: Date
    var selectDay: (Int) -> Void = { _ in }

    var body: some View {
        Group {
            if let best = MonthInsightBestDay(snapshot: snapshot, metric: metric, at: now) {
                let text = MonthInsightBestDayText(best: best, metric: metric, window: snapshot.window)
                Button { selectDay(best.day) } label: {
                    Text(text.summary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(text.help)
                .accessibilityLabel(text.help)
            } else {
                Text("No activity yet")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

struct MonthInsightBestDayText {
    let summary: String
    let help: String

    init(best: MonthInsightBestDay, metric: PRMetric, window: MonthWindow) {
        let date = window.dayTitle(best.day)
        summary = "Best day: \(best.count.formatted()) · \(date)"
        var detail = "List \(best.count.formatted()) \(best.count == 1 ? "PR" : "PRs") \(metric.rawValue) on \(date)."
        if best.tiedDays > 1 {
            detail += " Most recent of \(best.tiedDays.formatted()) days tied for best this month."
        }
        help = detail
    }
}
