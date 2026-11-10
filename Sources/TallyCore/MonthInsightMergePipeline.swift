import Foundation

/// With a goal of merges, the merges it still needs against this month's PRs still open that could make them.
/// The likely-finish range only extends the rate of merges so far, so it can't tell a month short of PRs to merge
/// from one whose PRs are written and waiting on review. Only PRs opened this month are in the snapshot, so older
/// PRs still open aren't counted and `stillOpen` is a floor.
public struct MonthInsightMergePipeline: Sendable, Equatable {
    /// Merges still needed to reach the goal. Matches `Pace.remaining`.
    public let remaining: Int
    /// PRs opened this month that GitHub still has open, drafts included. Matches `MergeFunnel.stillOpen`.
    public let stillOpen: Int

    /// Merges still needed once every PR still open has merged, or 0 when they cover the goal.
    public var shortfall: Int { max(remaining - stillOpen, 0) }

    /// Nil unless the goal counts merges, isn't reached yet, the month still has time left, and every unmerged PR's
    /// state is known: a snapshot saved before states were fetched can't say which of them can still merge.
    public init?(snapshot: MonthSnapshot, metric: PRMetric, goal: Int, at now: Date) {
        guard metric == .merged, snapshot.window.contains(now) else { return nil }
        let remaining = goal - snapshot.count(for: metric)
        guard remaining > 0, let stillOpen = snapshot.mergeFunnel.stillOpen else { return nil }
        self.remaining = remaining
        self.stillOpen = stillOpen
    }
}
