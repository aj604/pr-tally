import SwiftUI
import TallyCore

/// How long a merged pull request took from opening to merging, worn on its row, so a slow day or repository shows
/// which PRs held it up. It stands in for the plain "Merged" label in the opened list, and gives the merged list, which
/// otherwise leaves that label out, something to say. The time is rounded as `PullRequestWorkspaceElapsed` rounds it.
struct PullRequestWorkspaceMergeTime: Equatable {
    let elapsed: PullRequestWorkspaceElapsed

    init?(_ pr: PullRequest) {
        guard let mergedAt = pr.mergedAt else { return nil }
        elapsed = .init(seconds: mergedAt.timeIntervalSince(pr.createdAt))
    }

    /// Short enough to sit beside the row's time: "Merged in 5h".
    var label: String { "Merged in \(elapsed.short)" }

    /// `label` read out in words, since "5h" is written shorthand.
    var accessibilityLabel: String { "Merged in \(elapsed.spoken)" }

    /// The merged status's colour, as the label replaces it.
    var tint: Color { .purple }
}
