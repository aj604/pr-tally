import SwiftUI
import TallyCore

/// Whether an open PR's checks are failing, as the list words it. Only a failure is worth a label: a passing or
/// still-running PR needs nothing from its author, and a draft is expected to be red while it is worked on. Nothing
/// is said for a PR without checks or for a snapshot saved before they were fetched, so absence never reads as green.
struct PullRequestWorkspaceChecks: Equatable {
    init?(_ pr: PullRequest) {
        // GitHub keeps the rollup of a merged or closed PR's last commit; it no longer asks anything of the author.
        guard pr.state == .open, pr.mergedAt == nil, !pr.isDraft, pr.checks == .failure || pr.checks == .error
        else { return nil }
    }

    /// The label to show beside a row, or nil when the list already counts only merged PRs.
    static func badge(for pr: PullRequest, metric: PRMetric) -> Self? {
        metric == .merged ? nil : Self(pr)
    }

    var label: String { "CI failing" }

    var tint: Color { .red }
}
