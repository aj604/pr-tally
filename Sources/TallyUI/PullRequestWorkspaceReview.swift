import SwiftUI
import TallyCore

/// Where review stands on a PR that is still waiting on it, as the list words it. Only an open PR that is not a
/// draft has a review to wait on, and only where GitHub reports a decision, so nothing else gets a label.
struct PullRequestWorkspaceReview: Equatable {
    let decision: PullRequest.ReviewDecision

    init?(_ pr: PullRequest) {
        // GitHub keeps the decision on a PR after it merges or closes; it no longer says anything useful.
        guard pr.state == .open, pr.mergedAt == nil, !pr.isDraft, let decision = pr.reviewDecision else { return nil }
        self.decision = decision
    }

    /// The label to show beside a row, or nil when the list already counts only merged PRs.
    static func badge(for pr: PullRequest, metric: PRMetric) -> Self? {
        metric == .merged ? nil : Self(pr)
    }

    var label: String {
        switch decision {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Needs review"
        }
    }

    var tint: Color {
        switch decision {
        case .approved: .green
        case .changesRequested: .orange
        case .reviewRequired: .secondary
        }
    }
}
