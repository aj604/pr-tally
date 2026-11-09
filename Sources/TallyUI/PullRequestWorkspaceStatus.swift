import SwiftUI
import TallyCore

/// Where a pull request stands, as the list words it. Nil when GitHub's answer isn't known (a snapshot saved
/// before states were fetched), so the list shows nothing rather than guess "open".
struct PullRequestWorkspaceStatus: Equatable {
    enum Kind: Equatable { case open, draft, merged, closed }

    let kind: Kind

    init?(_ pr: PullRequest) {
        // A merge date is proof enough, even where the saved snapshot never recorded a state.
        if pr.mergedAt != nil || pr.state == .merged {
            kind = .merged
        } else if pr.state == .closed {
            kind = .closed
        } else if pr.state == .open {
            kind = pr.isDraft ? .draft : .open
        } else {
            return nil
        }
    }

    /// The status to show beside a row, or nil when the list already says it: every PR counted as merged is merged.
    static func badge(for pr: PullRequest, metric: PRMetric) -> Self? {
        metric == .merged ? nil : Self(pr)
    }

    var label: String {
        switch kind {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    var tint: Color {
        switch kind {
        case .open: .green
        case .draft: .secondary
        case .merged: .purple
        case .closed: .red
        }
    }
}
