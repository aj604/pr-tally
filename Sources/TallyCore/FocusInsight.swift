import Foundation

/// What a slice of the month's pull requests says beside the month they came from: how big a part of it the slice
/// is, how many of its PRs merged and how long they took, where the rest stand, and which repositories they're in.
/// A PR counts as merged on a merge date or GitHub's merged state. Open, draft and closed count only PRs whose state
/// GitHub reported, so a snapshot saved before states were fetched shows none of them rather than guessing "open".
public struct FocusInsight: Sendable, Equatable {
    /// PRs in the slice.
    public let count: Int
    /// PRs the same metric counted over the whole month, the slice's included.
    public let monthCount: Int
    public let merged: Int
    /// Middle of the open-to-merge times of the slice's merged PRs, or nil when none merged.
    public let medianTimeToMerge: TimeInterval?
    /// Open and not a draft.
    public let open: Int
    public let draft: Int
    /// Closed without merging.
    public let closed: Int
    /// The slice's repositories by count, highest first, with ties in name order.
    public let repositories: [RepoCount]

    public init(pullRequests: [PullRequest], monthCount: Int) {
        count = pullRequests.count
        self.monthCount = monthCount
        let landed = pullRequests.filter { $0.mergedAt != nil || $0.state == .merged }
        merged = landed.count
        let unmerged = pullRequests.filter { $0.mergedAt == nil && $0.state != .merged }
        open = unmerged.filter { $0.state == .open && !$0.isDraft }.count
        draft = unmerged.filter { $0.state == .open && $0.isDraft }.count
        closed = unmerged.filter { $0.state == .closed }.count
        let times = landed.compactMap { pr in pr.mergedAt.map { $0.timeIntervalSince(pr.createdAt) } }.sorted()
        medianTimeToMerge = times.isEmpty ? nil
            : times.count.isMultiple(of: 2) ? (times[times.count / 2 - 1] + times[times.count / 2]) / 2
            : times[times.count / 2]
        repositories = Dictionary(grouping: pullRequests, by: \.repository.nameWithOwner)
            .map { RepoCount(name: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// The slice's part of the month, or nil when the month counted nothing.
    public var share: Double? {
        monthCount > 0 ? Double(count) / Double(monthCount) : nil
    }
}

extension MonthSnapshot {
    /// The metric's count per day over the days the month has had so far, today included, or nil before the month.
    public func averagePerDay(for metric: PRMetric, at now: Date) -> Double? {
        let days = cumulativeCounts(for: metric, through: now).count
        return days > 0 ? Double(count(for: metric)) / Double(days) : nil
    }
}
