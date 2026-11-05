import Foundation
import TallyCore

/// The last good snapshot on disk, so a relaunch has numbers before GitHub answers, or if it doesn't.
public struct SnapshotCache: Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Too big for UserDefaults: a busy month is over a thousand pull requests.
    public static var standard: SnapshotCache {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SnapshotCache(url: support.appending(path: "PR Tally/last-snapshot.json"))
    }

    /// A missing or unreadable file just means starting without numbers.
    public func load() -> MonthSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(StoredSnapshot.self, from: data))?.snapshot
    }

    /// Best effort: failing to save only costs the numbers on the next launch. The file holds
    /// private repo names and PR titles, so only this user can read it.
    public func save(_ snapshot: MonthSnapshot) {
        guard let data = try? JSONEncoder().encode(StoredSnapshot(snapshot)) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: url, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private struct StoredSnapshot: Codable {
    struct StoredPullRequest: Codable {
        let id: String
        let title: String
        let url: URL
        let createdAt: Date
        let mergedAt: Date?
        let repository: String

        init(_ pr: PullRequest) {
            id = pr.id
            title = pr.title
            url = pr.url
            createdAt = pr.createdAt
            mergedAt = pr.mergedAt
            repository = pr.repository.nameWithOwner
        }

        var pullRequest: PullRequest {
            PullRequest(
                id: id, title: title, url: url, createdAt: createdAt, mergedAt: mergedAt,
                repository: .init(nameWithOwner: repository)
            )
        }
    }

    let login: String
    let monthStart: Date
    let calendar: Calendar
    let opened: [StoredPullRequest]
    let merged: [StoredPullRequest]
    let totalContributions: Int
    let fetchedAt: Date

    init(_ snapshot: MonthSnapshot) {
        login = snapshot.login
        monthStart = snapshot.window.start
        calendar = snapshot.window.calendar
        opened = snapshot.opened.map(StoredPullRequest.init)
        merged = snapshot.merged.map(StoredPullRequest.init)
        totalContributions = snapshot.totalContributions
        fetchedAt = snapshot.fetchedAt
    }

    var snapshot: MonthSnapshot {
        MonthSnapshot(
            login: login, window: MonthWindow(containing: monthStart, calendar: calendar),
            opened: opened.map(\.pullRequest), merged: merged.map(\.pullRequest),
            totalContributions: totalContributions, fetchedAt: fetchedAt
        )
    }
}
