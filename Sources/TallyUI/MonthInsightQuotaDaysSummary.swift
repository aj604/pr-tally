import SwiftUI
import TallyCore

/// How many of the month's days beat the daily quota, under the bars that show which ones.
struct MonthInsightQuotaDaysSummary: View {
    let quotaDays: MonthInsightQuotaDays
    let metric: PRMetric
    let goal: Int
    let window: MonthWindow

    var body: some View {
        let text = MonthInsightQuotaDaysText(quotaDays: quotaDays, metric: metric, goal: goal, window: window)
        Text(text.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .help(text.help)
    }
}

struct MonthInsightQuotaDaysText {
    let summary: String
    let help: String

    init(quotaDays: MonthInsightQuotaDays, metric: PRMetric, goal: Int, window: MonthWindow) {
        let days = quotaDays.days
        summary = "Beat the daily quota on \(quotaDays.beaten.formatted()) of \(days.formatted()) \(days == 1 ? "day" : "days")"
        let quota = quotaDays.quota.formatted(.number.precision(.fractionLength(0...1)))
        help = "Days with more than \(quota) PRs \(metric.rawValue), the goal of \(goal.formatted()) spread evenly "
            + "over \(window.dayCount) days. Their bars are green. Completed days count, and today once it beats the quota."
    }

    /// Top of the daily bars' scale, and where the quota line goes, if anywhere. The line stretches the scale to fit
    /// only while the tallest bar keeps at least half the height; past that the bars would flatten into a strip, and
    /// the summary already says that no day came close.
    static func scale(tallest: Int, quota: Double) -> (top: Double, rule: Double?) {
        let top = Double(max(tallest, 1))
        guard quota > 0, quota <= top * 2 else { return (top, nil) }
        return (max(top, quota), quota)
    }
}
