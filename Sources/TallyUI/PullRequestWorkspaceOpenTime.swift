import SwiftUI
import TallyCore

/// How long a pull request that is still open has been waiting, worn on its row in place of the plain "Open" or
/// "Draft" label, so the opened list shows which PRs are going stale as plainly as "Merged in" shows which were slow.
/// It counts from opening to `now`, rounded as `PullRequestWorkspaceElapsed` rounds it. A closed PR stopped waiting
/// at a time the snapshot doesn't record, and a PR whose state isn't known may not be open at all, so neither gets one.
struct PullRequestWorkspaceOpenTime: Equatable {
    let status: PullRequestWorkspaceStatus
    let elapsed: PullRequestWorkspaceElapsed

    init?(_ pr: PullRequest, at now: Date) {
        guard let status = PullRequestWorkspaceStatus(pr), status.kind == .open || status.kind == .draft else { return nil }
        self.status = status
        elapsed = .init(seconds: now.timeIntervalSince(pr.createdAt))
    }

    /// The status it stands in for, then the time: "Open for 3d", "Draft for 5h".
    var label: String { "\(status.label) for \(elapsed.short)" }

    /// `label` read out in words, since "3d" is written shorthand.
    var accessibilityLabel: String { "\(status.label) for \(elapsed.spoken)" }

    /// The status's colour, as the label replaces it.
    var tint: Color { status.tint }
}
