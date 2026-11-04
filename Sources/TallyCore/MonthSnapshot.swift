import Foundation

public struct PullRequest: Sendable, Equatable, Decodable, Identifiable {
    public struct Repository: Sendable, Equatable, Decodable {
        public let nameWithOwner: String
        public init(nameWithOwner: String) { self.nameWithOwner = nameWithOwner }
    }

    public let id: String
    public let title: String
    public let url: URL
    public let createdAt: Date
    public let mergedAt: Date?
    public let repository: Repository

    public init(id: String, title: String, url: URL, createdAt: Date, mergedAt: Date?, repository: Repository) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.mergedAt = mergedAt
        self.repository = repository
    }
}

/// Which pull requests count toward the goal.
public enum PRMetric: String, Sendable, CaseIterable, Identifiable {
    case opened, merged
    public var id: String { rawValue }
}

public struct RepoCount: Sendable, Equatable, Identifiable {
    public let name: String
    public let count: Int
    public var id: String { name }
}

/// One month of GitHub activity, as fetched at a moment in time.
public struct MonthSnapshot: Sendable, Equatable {
    public let login: String
    public let window: MonthWindow
    public let opened: [PullRequest]
    public let merged: [PullRequest]
    /// GitHub's profile-graph total: commits, PRs, reviews, and issues, including private work.
    public let totalContributions: Int
    public let fetchedAt: Date

    public init(
        login: String, window: MonthWindow, opened: [PullRequest], merged: [PullRequest],
        totalContributions: Int, fetchedAt: Date
    ) {
        self.login = login
        self.window = window
        self.opened = opened
        self.merged = merged
        self.totalContributions = totalContributions
        self.fetchedAt = fetchedAt
    }

    public func pullRequests(for metric: PRMetric) -> [PullRequest] {
        metric == .opened ? opened : merged
    }

    public func count(for metric: PRMetric) -> Int {
        pullRequests(for: metric).count
    }

    /// Count for each day of the month, indexed from the 1st.
    public func dailyCounts(for metric: PRMetric) -> [Int] {
        var counts = Array(repeating: 0, count: window.dayCount)
        for pr in pullRequests(for: metric) {
            let date = metric == .opened ? pr.createdAt : pr.mergedAt
            if let date, let day = window.dayIndex(of: date) {
                counts[day] += 1
            }
        }
        return counts
    }

    /// Running total per day from the 1st through the day of `now`, omitting days still to come.
    public func cumulativeCounts(for metric: PRMetric, through now: Date) -> [Int] {
        let daily = dailyCounts(for: metric)
        let days = now >= window.end ? daily.count : (window.dayIndex(of: now).map { $0 + 1 } ?? 0)
        var total = 0
        return daily.prefix(days).map { count in
            total += count
            return total
        }
    }

    public func todayCount(for metric: PRMetric, at now: Date) -> Int {
        guard let day = window.dayIndex(of: now) else { return 0 }
        return dailyCounts(for: metric)[day]
    }

    /// Repositories by count, highest first, with ties in name order.
    public func topRepositories(for metric: PRMetric, limit: Int = 5) -> [RepoCount] {
        Dictionary(grouping: pullRequests(for: metric), by: \.repository.nameWithOwner)
            .map { RepoCount(name: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
            .prefix(limit)
            .map { $0 }
    }
}
