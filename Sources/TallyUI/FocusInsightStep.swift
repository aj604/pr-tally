import TallyCore

/// Sideways from a zoomed slice to the one beside it of the same kind, so slices can be compared without stepping out
/// to the month: a repository to the next or previous in the top repos' order (every repository the listed count has,
/// not only the five shown), and a part of the merge funnel to the other part. Only to slices with PRs, the ones the
/// summary offers. Stepping days is the list's own, so a slice that names a day doesn't step here and the two
/// never move the same list. Nil when the slice has no neighbor.
struct FocusInsightStep: Equatable {
    struct Neighbor: Equatable {
        let focus: PullRequestFocus
        /// The neighbor's name, as its heading would title it.
        let title: String
    }

    let previous: Neighbor?
    let next: Neighbor?
    /// Where the slice sits among its kind, as "2 of 5".
    let position: String
    /// What the slices being stepped through are, for the buttons' help.
    let kind: String

    init?(snapshot: MonthSnapshot, metric goal: PRMetric, focus: PullRequestFocus) {
        let slices: [(focus: PullRequestFocus, title: String)]
        if focus.repository != nil {
            let repositories = snapshot.topRepositories(for: focus.listedMetric(goal: goal), limit: .max)
            slices = repositories.map { (PullRequestFocus(repository: $0.name, metric: focus.metric), $0.name) }
            kind = "repository"
        } else if let part = focus.funnel {
            let funnel = snapshot.mergeFunnel
            let parts: [(FunnelPart, Int, String)] = [
                (.notMerged, funnel.notMerged, "Opened, not merged"),
                (.carriedIn, funnel.carriedIn, "Opened before \(snapshot.window.monthTitle)"),
            ]
            slices = parts.filter { $0.1 > 0 || $0.0 == part }.map { (PullRequestFocus(funnel: $0.0), $0.2) }
            kind = "part of the merge funnel"
        } else {
            return nil
        }
        // Only a slice that is exactly one of these steps, so one that also names a day, or a repository with no PRs in
        // the count, is left alone.
        guard slices.count > 1, let index = slices.firstIndex(where: { $0.focus == focus }) else { return nil }
        previous = index > 0 ? Neighbor(focus: slices[index - 1].focus, title: slices[index - 1].title) : nil
        next = index + 1 < slices.count ? Neighbor(focus: slices[index + 1].focus, title: slices[index + 1].title) : nil
        position = "\((index + 1).formatted()) of \(slices.count.formatted())"
    }
}
