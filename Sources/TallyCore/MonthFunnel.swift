import Foundation

/// What became of the month's pull requests. Opened and merged are overlapping lists, not a
/// before and after: a merge this month may be of a PR opened long ago, so the two counts can't be divided.
/// They also come from separate searches that can disagree about a PR that merged between them, so these
/// figures reconcile the lists by PR and can briefly differ from `count(for:)`.
public struct MergeFunnel: Sendable, Equatable {
    /// PRs opened this month, including any merged this month that the opened list missed, so this never trails `openedAndMerged`.
    public let opened: Int
    /// PRs opened this month that have merged.
    public let openedAndMerged: Int
    /// PRs merged this month that were opened in an earlier month.
    public let carriedIn: Int
    /// Middle time from opening to merging, in seconds, across everything merged this month.
    public let medianTimeToMerge: TimeInterval?

    /// PRs opened this month with no merge yet, whether still open or closed without merging.
    public var notMerged: Int { opened - openedAndMerged }

    /// Portion of this month's opened PRs that have merged, or nil when none were opened.
    public var mergeRate: Double? {
        opened > 0 ? Double(openedAndMerged) / Double(opened) : nil
    }

    public var isEmpty: Bool { opened == 0 && carriedIn == 0 && medianTimeToMerge == nil }
}

extension MonthSnapshot {
    public var mergeFunnel: MergeFunnel {
        let landed = landedThisMonth
        let carriedIn = landed.values.filter { $0.createdAt < window.start }
        let openedAndMerged = landed.values.filter { $0.createdAt >= window.start }
        let times = landed.values.map { $0.mergedAt!.timeIntervalSince($0.createdAt) }.sorted()
        var median: TimeInterval?
        if !times.isEmpty {
            median = (times[(times.count - 1) / 2] + times[times.count / 2]) / 2
        }
        return MergeFunnel(
            opened: openedAndMerged.count + notMerged(besides: landed).count,
            openedAndMerged: openedAndMerged.count,
            carriedIn: carriedIn.count,
            medianTimeToMerge: median
        )
    }

    /// The PRs behind `mergeFunnel.notMerged`: opened this month, each once, with no merge this month in either list.
    public var notMergedPullRequests: [PullRequest] {
        notMerged(besides: landedThisMonth)
    }

    /// The PRs behind `mergeFunnel.carriedIn`: merged this month, each once, opened in an earlier month.
    public var carriedInPullRequests: [PullRequest] {
        let landed = landedThisMonth
        var seen: Set<String> = []
        return (merged + opened).filter { pr in
            landed[pr.id] == pr && pr.createdAt < window.start && seen.insert(pr.id).inserted
        }
    }

    /// One set of this month's merges, from either list, so every merged figure agrees with the others.
    private var landedThisMonth: [String: PullRequest] {
        var landed: [String: PullRequest] = [:]
        for pr in merged + opened where landed[pr.id] == nil {
            if let mergedAt = pr.mergedAt, window.contains(mergedAt) {
                landed[pr.id] = pr
            }
        }
        return landed
    }

    private func notMerged(besides landed: [String: PullRequest]) -> [PullRequest] {
        var seen: Set<String> = []
        return opened.filter { pr in
            window.contains(pr.createdAt) && landed[pr.id] == nil && seen.insert(pr.id).inserted
        }
    }
}
