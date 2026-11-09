import Foundation

/// What a slice of the month's pull requests says beside the month they came from: how big a part of it the slice
/// is, how many of its PRs merged and how long they took, where the rest stand, and which repositories they're in.
/// A PR counts as merged on a merge date or GitHub's merged state. Open, draft and closed count only PRs whose state
/// GitHub reported, so a snapshot saved before states were fetched shows none of them rather than guessing "open"; the
/// longest any of them has waited likewise comes only from PRs GitHub reported open.
/// Size likewise counts only PRs whose lines GitHub reported.
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
    /// When the open PR that has waited longest was opened, or nil when none is open. Drafts aren't waiting on anyone.
    public let oldestOpenSince: Date?
    public let draft: Int
    /// Closed without merging.
    public let closed: Int
    /// The slice's repositories by count, highest first, with ties in name order.
    public let repositories: [RepoCount]
    /// Middle of the slice's sizes in lines added plus deleted, or nil when no PR's size is known.
    public let medianLinesChanged: Double?

    public init(pullRequests: [PullRequest], monthCount: Int) {
        count = pullRequests.count
        self.monthCount = monthCount
        let landed = pullRequests.filter { $0.mergedAt != nil || $0.state == .merged }
        merged = landed.count
        let unmerged = pullRequests.filter { $0.mergedAt == nil && $0.state != .merged }
        let waiting = unmerged.filter { $0.state == .open && !$0.isDraft }
        open = waiting.count
        oldestOpenSince = waiting.map(\.createdAt).min()
        draft = unmerged.filter { $0.state == .open && $0.isDraft }.count
        closed = unmerged.filter { $0.state == .closed }.count
        medianTimeToMerge = landed.medianTimeToMerge
        medianLinesChanged = pullRequests.medianLinesChanged
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
    /// The metric's count per finished day: the days before today, or every day once the month is over. Nil until a
    /// day has finished. Today is left out, since a day still under way would pull the average down.
    public func averagePerFinishedDay(for metric: PRMetric, at now: Date) -> Double? {
        let days = finishedDays(at: now)
        guard days > 0 else { return nil }
        return Double(dailyCounts(for: metric).prefix(days).reduce(0, +)) / Double(days)
    }

    /// What a finished day had counted by the time of day `now` is at, on average, so a day still under way is measured
    /// against the same hours of the others rather than their whole. Nil outside the month and on its first day, when no
    /// day has finished. The time is read off the clock in the zone the month was counted in, so a day that changes the
    /// clocks lines up with the rest.
    public func averageByTimeOfDay(for metric: PRMetric, at now: Date) -> Double? {
        guard let today = window.dayIndex(of: now), today > 0 else { return nil }
        let time = clockTime(of: now)
        let counted = pullRequests(for: metric).filter { pr in
            guard let date = metric == .opened ? pr.createdAt : pr.mergedAt,
                  let day = window.dayIndex(of: date), day < today else { return false }
            return clockTime(of: date) < time
        }
        return Double(counted.count) / Double(today)
    }

    /// Seconds past midnight on the clock, so 9 AM is the same time of day whether or not the clocks changed that night.
    private func clockTime(of date: Date) -> Int {
        let clock = window.calendar.dateComponents([.hour, .minute, .second], from: date)
        return clock.hour! * 3_600 + clock.minute! * 60 + clock.second!
    }

    private func finishedDays(at now: Date) -> Int {
        now >= window.end ? window.dayCount : window.dayIndex(of: now) ?? 0
    }

    /// The middle size, in lines added plus deleted, of the PRs the metric counted this month, or nil when no PR's
    /// size is known.
    public func medianLinesChanged(for metric: PRMetric) -> Double? {
        pullRequests(for: metric).medianLinesChanged
    }

    /// The middle open-to-merge time of the PRs the metric counted this month that have merged, or nil when none has.
    public func medianTimeToMerge(for metric: PRMetric) -> TimeInterval? {
        pullRequests(for: metric).medianTimeToMerge
    }
}

extension [PullRequest] {
    fileprivate var medianLinesChanged: Double? {
        median(compactMap(\.linesChanged).map(Double.init))
    }

    /// Over the PRs with a merge date; one merged by state alone has no time to measure.
    fileprivate var medianTimeToMerge: TimeInterval? {
        median(compactMap { pr in pr.mergedAt.map { $0.timeIntervalSince(pr.createdAt) } })
    }
}

/// The middle value, or the mean of the middle two, or nil for none.
private func median(_ values: [Double]) -> Double? {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return nil }
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}
