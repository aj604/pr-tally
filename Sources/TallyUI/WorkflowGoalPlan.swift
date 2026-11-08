import SwiftUI
import TallyCore

/// The workload implied by the goal being edited, using the same daily share as the summary.
struct WorkflowGoalPlan: Equatable {
    let metric: PRMetric
    let dailyQuota: Double
    let remaining: Int?
    let moreToday: Int?

    var quotaText: String {
        "Average: \(dailyQuota.formatted(.number.precision(.fractionLength(0...1)))) per day this month (\(metric.noun))."
    }

    var progressText: String {
        guard let remaining, let moreToday else {
            return "Waiting for this month's numbers to calculate what's left."
        }
        if remaining == 0 { return "Goal reached for \(metric.noun)." }
        let today = moreToday > 0 ? "\(moreToday.formatted()) more today" : "Today's share complete"
        return "\(metric.noun): \(remaining.formatted()) left this month · \(today)."
    }
}

extension TallyStore {
    func workflowGoalPlan(at now: Date = Date(), calendar: Calendar = .current) -> WorkflowGoalPlan {
        let snapshot = currentSnapshot(at: now, calendar: calendar)
        let window = snapshot?.window ?? MonthWindow(containing: now, calendar: calendar)
        let pace = snapshot.map { Pace(goal: goal, count: $0.count(for: metric), window: window, at: now) }
        let today = snapshot?.todayCount(for: metric, at: now) ?? 0
        return WorkflowGoalPlan(
            metric: metric, dailyQuota: Double(goal) / Double(window.dayCount),
            remaining: pace?.remaining, moreToday: pace?.leftToday(today: today)
        )
    }
}

struct WorkflowGoalPreview: View {
    let plan: WorkflowGoalPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.quotaText)
            Text(plan.progressText)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
