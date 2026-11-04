import Foundation
import Testing
@testable import TallyCore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 20))!
private let monthStart = utc.date(from: DateComponents(year: 2026, month: 11, day: 1))!

private func pr(_ id: Int, createdAt: Date, mergedAt: Date? = nil, repo: String = "me/app") -> PullRequest {
    PullRequest(
        id: "PR_\(id)", title: "PR \(id)", url: URL(string: "https://github.com/\(repo)/pull/\(id)")!,
        createdAt: createdAt, mergedAt: mergedAt, repository: .init(nameWithOwner: repo)
    )
}

/// Behaves like GitHub search, including refusing to return more than 1,000 results.
private final class FakeGitHub: Sendable {
    let prs: [PullRequest]
    let failure: String?

    init(prs: [PullRequest], failure: String? = nil) {
        self.prs = prs
        self.failure = failure
    }

    func respond(to body: Data) throws -> Data {
        let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let variables = request["variables"] as! [String: String]
        if let failure {
            return try JSONSerialization.data(withJSONObject: ["data": NSNull(), "errors": [["message": failure]]])
        }
        guard let query = variables["q"] else {
            return try JSONSerialization.data(withJSONObject: ["data": ["viewer": [
                "login": "me",
                "contributionsCollection": ["contributionCalendar": ["totalContributions": 42]],
            ]]])
        }
        return try JSONSerialization.data(withJSONObject: ["data": ["search": search(query, after: variables["after"])]])
    }

    private func search(_ query: String, after: String?) -> [String: Any] {
        let isCreated = query.contains("created:")
        let range = query.components(separatedBy: isCreated ? "created:" : "merged:")[1].components(separatedBy: "..")
        let from = try! Date(range[0], strategy: .iso8601)
        let to = try! Date(range[1], strategy: .iso8601)
        let matches = prs.filter {
            guard let date = isCreated ? $0.createdAt : $0.mergedAt else { return false }
            return date >= from && date <= to
        }
        let offset = after.flatMap(Int.init) ?? 0
        let page = Array(matches.prefix(FakeGitHub.cap).dropFirst(offset).prefix(100))
        let next = offset + page.count
        return [
            "issueCount": matches.count,
            "pageInfo": ["hasNextPage": next < min(matches.count, FakeGitHub.cap), "endCursor": String(next)],
            "nodes": page.map { pr in
                [
                    "id": pr.id, "title": pr.title, "url": pr.url.absoluteString,
                    "createdAt": pr.createdAt.formatted(.iso8601),
                    "mergedAt": pr.mergedAt.map { $0.formatted(.iso8601) } as Any? ?? NSNull(),
                    "repository": ["nameWithOwner": pr.repository.nameWithOwner],
                ] as [String: Any]
            },
        ]
    }

    private static let cap = 1000
}

private func client(_ fake: FakeGitHub) -> GitHubClient {
    GitHubClient { try fake.respond(to: $0) }
}

@Suite struct GitHubClientTests {
    @Test func fetchesEveryPullRequestPastTheSearchCap() async throws {
        // 2,500 PRs, one every ~14 minutes, comfortably exceeds the 1,000-result cap.
        let prs = (0..<2500).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 840)) }
        let snapshot = try await client(FakeGitHub(prs: prs)).fetchSnapshot(at: now, calendar: utc)
        #expect(snapshot.count(for: .opened) == 2500)
        #expect(Set(snapshot.opened.map(\.id)).count == 2500)
    }

    @Test func tracksOpenedAndMergedSeparately() async throws {
        let lastMonth = utc.date(from: DateComponents(year: 2026, month: 10, day: 30))!
        let prs = [
            pr(1, createdAt: monthStart),
            pr(2, createdAt: lastMonth, mergedAt: monthStart.addingTimeInterval(60)),
            pr(3, createdAt: lastMonth),
        ]
        let snapshot = try await client(FakeGitHub(prs: prs)).fetchSnapshot(at: now, calendar: utc)
        #expect(snapshot.opened.map(\.id) == ["PR_1"])
        #expect(snapshot.merged.map(\.id) == ["PR_2"])
        #expect(snapshot.login == "me")
        #expect(snapshot.totalContributions == 42)
    }

    @Test func graphQLErrorsFailTheFetchInsteadOfUndercounting() async {
        let fake = FakeGitHub(prs: [], failure: "Search timed out")
        await #expect(throws: GitHubError.graphQL("Search timed out")) {
            _ = try await client(fake).fetchSnapshot(at: now, calendar: utc)
        }
    }
}

@Suite struct MonthSnapshotTests {
    private let window = MonthWindow(containing: now, calendar: utc)

    private func snapshot(_ prs: [PullRequest]) -> MonthSnapshot {
        MonthSnapshot(
            login: "me", window: window, opened: prs, merged: prs.filter { $0.mergedAt != nil },
            totalContributions: 0, fetchedAt: now
        )
    }

    @Test func bucketsByDayUsingTheMetricsOwnDate() {
        let day3 = monthStart.addingTimeInterval(2 * 86_400)
        let day5 = monthStart.addingTimeInterval(4 * 86_400)
        let result = snapshot([pr(1, createdAt: day3), pr(2, createdAt: day3, mergedAt: day5)])
        #expect(result.dailyCounts(for: .opened)[2] == 2)
        #expect(result.dailyCounts(for: .merged)[4] == 1)
        #expect(result.dailyCounts(for: .merged)[2] == 0)
        #expect(result.dailyCounts(for: .opened).count == 30)
        #expect(result.todayCount(for: .opened, at: day3) == 2)
    }

    @Test func runningTotalStopsAtToday() {
        let day2 = monthStart.addingTimeInterval(86_400)
        let result = snapshot([pr(1, createdAt: monthStart), pr(2, createdAt: day2), pr(3, createdAt: day2)])
        #expect(result.cumulativeCounts(for: .opened, through: day2.addingTimeInterval(86_400)) == [1, 3, 3])
        #expect(result.cumulativeCounts(for: .opened, through: window.end).count == 30)
        #expect(result.cumulativeCounts(for: .opened, through: monthStart.addingTimeInterval(-1)).isEmpty)
    }

    @Test func ranksRepositoriesByCountThenName() {
        let result = snapshot([
            pr(1, createdAt: now, repo: "me/b"), pr(2, createdAt: now, repo: "me/c"),
            pr(3, createdAt: now, repo: "me/c"), pr(4, createdAt: now, repo: "me/a"),
        ])
        #expect(result.topRepositories(for: .opened, limit: 2).map(\.name) == ["me/c", "me/a"])
    }
}

@Suite struct TokenProviderTests {
    @Test func prefersTheSavedTokenOverTheCLI() async {
        let provider = TokenProvider(override: { "saved" }, cli: { "cli" })
        #expect(await provider.token() == "saved")
    }

    @Test func fallsBackToTheCLIWhenNothingIsSaved() async {
        let provider = TokenProvider(override: { "" }, cli: { "cli" })
        #expect(await provider.token() == "cli")
    }

    @Test func reportsNoTokenWhenNeitherSourceHasOne() async {
        let provider = TokenProvider(override: { nil }, cli: { nil })
        #expect(await provider.token() == nil)
    }

    @Test func runReturnsTrimmedOutputAndHandlesFailure() {
        #expect(GitHubCLI.run("/bin/echo", arguments: ["hi"]) == "hi")
        #expect(GitHubCLI.run("/usr/bin/false", arguments: []) == nil)
        #expect(GitHubCLI.run("/nonexistent/gh", arguments: []) == nil)
    }

    @Test func runGivesUpOnAStuckCommand() {
        #expect(GitHubCLI.run("/bin/sleep", arguments: ["30"], timeout: 0.2) == nil)
    }
}

@Suite struct KeychainTokenTests {
    @Test func savesReplacesAndDeletes() {
        let keychain = KeychainToken(service: "com.aj604.prtally.tests.\(UUID().uuidString)")
        defer { keychain.delete() }
        #expect(keychain.read() == nil)
        #expect(keychain.save("first"))
        #expect(keychain.save("second"))
        #expect(keychain.read() == "second")
        keychain.delete()
        #expect(keychain.read() == nil)
    }
}
