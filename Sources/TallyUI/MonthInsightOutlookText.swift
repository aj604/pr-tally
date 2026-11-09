import TallyCore

/// The chart's "Likely finish" line, with how that range compares to the goal when the goal is still open.
struct MonthInsightOutlookText: Equatable {
    let line: String
    let help: String
    /// What VoiceOver says for the chart: the same verdict, without the middle dot and en dash read aloud.
    let spoken: String

    init(projection: MonthProjection, goal: Int) {
        let range = "\(projection.low.formatted())–\(projection.high.formatted())"
        let goalText = goal.formatted()
        let verdict: String?
        switch MonthInsightOutlook(projection: projection, goal: goal) {
        case .likelyToReach:
            line = "Likely finish: \(range) · goal in reach"
            verdict = "goal in reach"
            help = "The goal of \(goalText) is at or below the low end of the range, so the current rate reaches it."
        case .withinRange:
            line = "Likely finish: \(range) · goal still open"
            verdict = "goal still open"
            help = "The goal of \(goalText) falls inside the range, so the rest of the month decides it."
        case .outOfReach:
            line = "Likely finish: \(range) · short of the goal"
            verdict = "short of the goal"
            help = "The goal of \(goalText) is above the range, so it takes a faster pace than so far."
        case nil:
            line = "Likely finish: \(range)"
            verdict = nil
            help = "Where the month likely ends if the days to come look like the days so far."
        }
        let spokenRange = "Likely finish \(projection.low.formatted()) to \(projection.high.formatted())"
        spoken = verdict.map { "\(spokenRange), \($0)" } ?? spokenRange
    }
}
