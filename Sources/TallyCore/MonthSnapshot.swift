import Foundation

public struct PullRequest: Sendable, Equatable, Decodable, Identifiable {
    public struct Repository: Sendable, Equatable, Decodable {
        public let nameWithOwner: String
        public init(nameWithOwner: String) { self.nameWithOwner = nameWithOwner }
    }

    /// GitHub's own word for where a PR stands.
    public enum State: String, Sendable, Equatable, Decodable {
        case open = "OPEN"
        case closed = "CLOSED"
        case merged = "MERGED"
    }

    /// Where review stands on a PR whose repository asks for reviews.
    public enum ReviewDecision: String, Sendable, Equatable, Decodable {
        case approved = "APPROVED"
        case changesRequested = "CHANGES_REQUESTED"
        case reviewRequired = "REVIEW_REQUIRED"
    }

    /// How the latest commit's checks and statuses stand, in GitHub's words.
    public enum ChecksState: String, Sendable, Equatable, Decodable {
        case success = "SUCCESS"
        case pending = "PENDING"
        case expected = "EXPECTED"
        case failure = "FAILURE"
        case error = "ERROR"
    }

    public let id: String
    public let title: String
    public let url: URL
    public let createdAt: Date
    public let mergedAt: Date?
    public let repository: Repository
    /// Nil when GitHub didn't say, as for a snapshot saved before this was fetched, or a state this app
    /// doesn't know. Nil means "unknown", never "open".
    public let state: State?
    /// Only meaningful while `state` is open: GitHub keeps the flag on a PR after it merges or closes.
    public let isDraft: Bool
    /// Nil when GitHub reports none: the repository doesn't require reviews, or the snapshot predates this field.
    /// Nil means "no signal", never "approved" or "unreviewed".
    public let reviewDecision: ReviewDecision?
    /// Nil when the PR has no checks or statuses at all, or the snapshot predates this field, or GitHub used a state
    /// this app doesn't know. Nil means "no signal", never "passing".
    public let checks: ChecksState?
    /// Lines added, or nil when the snapshot predates this field. Nil means "unknown", never "none".
    public let additions: Int?
    /// Lines deleted, or nil when the snapshot predates this field.
    public let deletions: Int?

    public init(
        id: String, title: String, url: URL, createdAt: Date, mergedAt: Date?, repository: Repository,
        state: State? = nil, isDraft: Bool = false, reviewDecision: ReviewDecision? = nil,
        checks: ChecksState? = nil, additions: Int? = nil, deletions: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.mergedAt = mergedAt
        self.repository = repository
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.checks = checks
        self.additions = additions
        self.deletions = deletions
    }

    /// Lines added and deleted together, GitHub's measure of a PR's size, or nil when either is unknown.
    public var linesChanged: Int? {
        guard let additions, let deletions else { return nil }
        return additions + deletions
    }

    private struct ChecksRollup: Decodable {
        let state: ChecksState?

        init(from decoder: Decoder) throws {
            state = (try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(ChecksState.self, forKey: .state)) ?? nil
        }

        private enum CodingKeys: String, CodingKey { case state }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, url, createdAt, mergedAt, repository, state, isDraft, reviewDecision, statusCheckRollup
        case additions, deletions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(URL.self, forKey: .url)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        mergedAt = try container.decodeIfPresent(Date.self, forKey: .mergedAt)
        repository = try container.decode(Repository.self, forKey: .repository)
        // A state added to GitHub later must not fail the whole refresh, so it reads as unknown.
        state = (try? container.decodeIfPresent(State.self, forKey: .state)) ?? nil
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        // Same tolerance as `state`: a decision GitHub adds later reads as no signal.
        reviewDecision = (try? container.decodeIfPresent(ReviewDecision.self, forKey: .reviewDecision)) ?? nil
        // GitHub nests the state in a rollup object that is null for a PR without checks.
        let rollup = (try? container.decodeIfPresent(ChecksRollup.self, forKey: .statusCheckRollup)) ?? nil
        checks = rollup?.state
        additions = try container.decodeIfPresent(Int.self, forKey: .additions)
        deletions = try container.decodeIfPresent(Int.self, forKey: .deletions)
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
