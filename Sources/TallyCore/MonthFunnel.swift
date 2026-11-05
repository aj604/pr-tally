import Foundation

/// What became of the month's pull requests. Opened and merged are overlapping lists, not a
/// before and after: a merge this month may be of a PR opened long ago, so the two counts can't be divided.
public struct MergeFunnel: Sendable, Equatable {
    /// PRs opened this month.
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
        let times = merged.compactMap { pr in pr.mergedAt.map { $0.timeIntervalSince(pr.createdAt) } }.sorted()
        var median: TimeInterval?
        if !times.isEmpty {
            median = (times[(times.count - 1) / 2] + times[times.count / 2]) / 2
        }
        return MergeFunnel(
            opened: opened.count,
            openedAndMerged: opened.filter { $0.mergedAt != nil }.count,
            carriedIn: merged.filter { $0.createdAt < window.start }.count,
            medianTimeToMerge: median
        )
    }
}
