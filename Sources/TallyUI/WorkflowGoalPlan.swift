import SwiftUI
import TallyCore

/// The workload implied by the goal being edited, using the same daily share as the summary, and how it compares
/// with the pace so far this month, so a goal can be chosen against what's actually being done.
struct WorkflowGoalPlan: Equatable {
    /// How the month's pace so far compares with the goal. Nil until this month's numbers arrive.
    struct Outlook: Equatable {
        /// PRs a day so far, with the same one-day floor as the summary's month-end projection.
        let averagePerDay: Double
        /// The month-end count if that pace continues, as the summary's "On track for".
        let projected: Int
        /// PRs needed each day from the start of today, as the summary's "Needed / day".
        let neededPerDay: Double
        let daysRemaining: Int
        /// Whole days of the month already over. The pace is only offered as a goal once they span a week.
        let daysElapsed: Int
    }

    /// A week covers both workdays and a weekend, so its pace says something about the month. A day or two doesn't:
    /// a busy Monday would project a goal no month reaches.
    static let daysBeforeSuggesting = 7

    let metric: PRMetric
    let goal: Int
    let dailyQuota: Double
    let remaining: Int?
    let moreToday: Int?
    let outlook: Outlook?

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

    /// Whether this month's pace reaches the goal, and if not, what reaching it takes from here.
    var outlookText: String? {
        guard let outlook, let remaining else { return nil }
        let pace = "\(Self.perDay(outlook.averagePerDay)) a day so far ends the month near \(outlook.projected.formatted())"
        if remaining == 0 || outlook.projected >= goal { return "On track: \(pace)." }
        let days = outlook.daysRemaining == 1 ? "today, the last day" : "a day for the \(outlook.daysRemaining) days left"
        return "Short of the goal: \(pace). Reaching it takes \(Self.perDay(outlook.neededPerDay)) \(days)."
    }

    /// The month-end count this month's pace leads to, offered as the goal once a week of the month is over and it
    /// differs from the goal being edited.
    var suggestedGoal: Int? {
        guard let outlook, outlook.daysElapsed >= Self.daysBeforeSuggesting, outlook.projected >= 1,
            outlook.projected != goal
        else { return nil }
        return outlook.projected
    }

    private static func perDay(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

extension TallyStore {
    func workflowGoalPlan(at now: Date = Date(), calendar: Calendar = .current) -> WorkflowGoalPlan {
        let snapshot = currentSnapshot(at: now, calendar: calendar)
        let window = snapshot?.window ?? MonthWindow(containing: now, calendar: calendar)
        let pace = snapshot.map { Pace(goal: goal, count: $0.count(for: metric), window: window, at: now) }
        let today = snapshot?.todayCount(for: metric, at: now) ?? 0
        let outlook = pace.map {
            WorkflowGoalPlan.Outlook(
                averagePerDay: Double($0.count) / max(window.elapsedFraction(at: now) * Double(window.dayCount), 1),
                projected: $0.projected, neededPerDay: $0.neededPerDay(today: today),
                daysRemaining: $0.daysRemaining, daysElapsed: window.dayIndex(of: now) ?? 0
            )
        }
        return WorkflowGoalPlan(
            metric: metric, goal: goal, dailyQuota: Double(goal) / Double(window.dayCount),
            remaining: pace?.remaining, moreToday: pace?.leftToday(today: today), outlook: outlook
        )
    }
}

struct WorkflowGoalPreview: View {
    let plan: WorkflowGoalPlan
    /// Sets the goal to the plan's suggestion.
    let useSuggestion: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.quotaText)
            Text(plan.progressText)
            if let outlookText = plan.outlookText {
                Text(outlookText)
            }
            if let suggestedGoal = plan.suggestedGoal {
                Button("Set goal to \(suggestedGoal.formatted()), this month's pace") { useSuggestion(suggestedGoal) }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
