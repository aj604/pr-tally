import SwiftUI
import TallyCore

/// The recent total and, once two full weeks exist, a like-for-like comparison beside the daily chart.
struct MonthInsightActivitySummary: View {
    let snapshot: MonthSnapshot
    let metric: PRMetric
    let now: Date

    var body: some View {
        if let activity = MonthInsightActivity(snapshot: snapshot, metric: metric, at: now) {
            let text = MonthInsightActivityText(activity: activity, metric: metric, window: snapshot.window)
            VStack(alignment: .leading, spacing: 2) {
                Text(text.total)
                if let comparison = text.comparison { Text(comparison) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .help(text.help)
        }
    }
}

struct MonthInsightActivityText {
    let total: String
    let comparison: String?
    let help: String

    init(activity: MonthInsightActivity, metric: PRMetric, window: MonthWindow) {
        let days = activity.recentDays.count
        let verb = metric == .opened ? "opened" : "merged"
        total = "Last \(days) full \(days == 1 ? "day" : "days"): \(activity.recentCount.formatted()) \(verb)"
        comparison = activity.change.map { change in
            if change == 0 { return "Same as previous 7 days" }
            return "\(abs(change).formatted()) \(change > 0 ? "more" : "fewer") than previous 7 days"
        }
        func dates(_ days: Range<Int>) -> String {
            let first = window.dayTitle(days.lowerBound)
            let last = window.dayTitle(days.upperBound - 1)
            return days.count == 1 ? first : "\(first)–\(last)"
        }
        var detail = "\(dates(activity.recentDays)): \(activity.recentCount.formatted()) PRs \(verb)."
        if let previousDays = activity.previousDays, let previousCount = activity.previousCount {
            detail += " \(dates(previousDays)): \(previousCount.formatted()) PRs \(verb)."
        }
        help = detail + " Completed days only, within this month; today is excluded."
    }
}
