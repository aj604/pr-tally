import TallyCore

/// The chart's "Merges to go" line, under the likely finish: whether this month's PRs still open could make the
/// merges the goal still needs, or how many more it takes to open.
struct MonthInsightMergePipelineText: Equatable {
    let line: String
    let help: String
    /// What VoiceOver says for the chart, without the middle dot read aloud.
    let spoken: String

    init(pipeline: MonthInsightMergePipeline, goal: Int) {
        let remaining = pipeline.remaining.formatted()
        let open = pipeline.stillOpen.formatted()
        let goalText = goal.formatted()
        let verdict: String
        if pipeline.stillOpen == 0 {
            verdict = "none still open"
            help = "None of the PRs opened this month are still open, so the \(remaining) \(pipeline.remaining == 1 ? "merge" : "merges") the goal "
                + "of \(goalText) still needs come from PRs not opened yet, or opened before this month."
        } else if pipeline.shortfall == 0 {
            verdict = "\(open) still open could cover \(pipeline.remaining == 1 ? "it" : "them")"
            help = "Merging \(remaining) of the \(open) PRs opened this month and still open, drafts included, "
                + "reaches the goal of \(goalText) without opening more."
        } else {
            let short = pipeline.shortfall.formatted()
            verdict = "\(open) still open, \(short) more to open"
            help = "Merging all \(open) PRs opened this month and still open, drafts included, leaves \(short) more "
                + "to open and merge for the goal of \(goalText). PRs opened before this month aren't counted."
        }
        line = "Merges to go: \(remaining) · \(verdict)"
        spoken = "Merges to go \(remaining), \(verdict)"
    }
}
