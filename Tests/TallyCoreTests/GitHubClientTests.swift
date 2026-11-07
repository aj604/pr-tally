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
    /// Cursors that don't show where a page starts, so the client can only follow them.
    let opaqueCursors: Bool
    /// Found once a page of opened PRs at or past `arriveAfter` has been served, and listed at `arrivalPosition`:
    /// first, as GitHub lists the newest, unless told otherwise.
    let arrivals: [PullRequest]
    let arrivalPosition: Int
    /// Gone from search, as when a repository is deleted, at the same moment the arrivals appear.
    let departures: Set<String>
    let arriveAfter: Int
    private let arrived = Box(false)

    init(
        prs: [PullRequest], failure: String? = nil, opaqueCursors: Bool = false,
        arrivals: [PullRequest] = [], arrivalPosition: Int = 0, departures: Set<String> = [], arriveAfter: Int = 0
    ) {
        self.prs = prs
        self.failure = failure
        self.opaqueCursors = opaqueCursors
        self.arrivals = arrivals
        self.arrivalPosition = arrivalPosition
        self.departures = departures
        self.arriveAfter = arriveAfter
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
        var current = prs
        if arrived.value {
            current.removeAll { departures.contains($0.id) }
            current.insert(contentsOf: arrivals, at: arrivalPosition)
        }
        let matches = current.filter {
            guard let date = isCreated ? $0.createdAt : $0.mergedAt else { return false }
            return date >= from && date <= to
        }
        let offset = after.flatMap(offset(of:)) ?? 0
        if isCreated, offset >= arriveAfter { arrived.value = true }
        let page = Array(matches.prefix(FakeGitHub.cap).dropFirst(offset).prefix(100))
        let next = offset + page.count
        return [
            "issueCount": matches.count,
            "pageInfo": ["hasNextPage": next < min(matches.count, FakeGitHub.cap), "endCursor": cursor(at: next)],
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

    /// GitHub's cursors are the count of results so far after `cursor:`, in base64.
    private func cursor(at offset: Int) -> String {
        opaqueCursors ? "page-\(offset)" : Data("cursor:\(offset)".utf8).base64EncodedString()
    }

    private func offset(of cursor: String) -> Int? {
        if opaqueCursors { return Int(cursor.replacingOccurrences(of: "page-", with: "")) }
        return Data(base64Encoded: cursor).flatMap { Int(String(decoding: $0, as: UTF8.self).dropFirst("cursor:".count)) }
    }

    private static let cap = 1000
}

/// Counts requests, and the most in flight at once.
private actor Overlap {
    private var inFlight = 0
    private(set) var peak = 0
    private(set) var requests = 0

    func begin() {
        inFlight += 1
        requests += 1
        peak = max(peak, inFlight)
    }

    func end() { inFlight -= 1 }
}

private func client(_ fake: FakeGitHub) -> GitHubClient {
    GitHubClient { try fake.respond(to: $0) }
}

/// Holds back the second page until the third has been answered, as GitHub may answer pages sent together.
private func clientAnsweringOutOfOrder(_ fake: FakeGitHub) -> GitHubClient {
    let answeredThird = Box(false)
    return GitHubClient { body in
        let offset = pageOffset(in: body)
        if (1..<150).contains(offset) {
            // A client that sends pages one at a time never asks for the third first, so stop waiting eventually.
            let deadline = ContinuousClock.now + .seconds(1)
            while !answeredThird.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        }
        let reply = try fake.respond(to: body)
        if (150..<250).contains(offset) { answeredThird.value = true }
        return reply
    }
}

/// Where the page a request asks for starts, from GitHub's `cursor:N`.
private func pageOffset(in body: Data) -> Int {
    let request = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
    guard let cursor = (request["variables"] as! [String: String])["after"],
        let decoded = Data(base64Encoded: cursor)
    else { return 0 }
    return Int(String(decoding: decoded, as: UTF8.self).dropFirst("cursor:".count)) ?? 0
}

private func client(_ fake: FakeGitHub, overlap: Overlap) -> GitHubClient {
    GitHubClient { body in
        await overlap.begin()
        // Long enough for requests sent together to overlap.
        try? await Task.sleep(for: .milliseconds(50))
        await overlap.end()
        return try fake.respond(to: body)
    }
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

    @Test func fetchesAHeavyMonthsPagesTogetherWithoutAskingForAnyTwice() async throws {
        // 800 PRs opened and merged through the month: nine pages of each, since each page after the first
        // starts on the PR the one before ended on.
        let prs = (0..<800).map {
            let created = monthStart.addingTimeInterval(Double($0) * 3000)
            return pr($0, createdAt: created, mergedAt: created.addingTimeInterval(600))
        }
        let overlap = Overlap()
        let snapshot = try await client(FakeGitHub(prs: prs), overlap: overlap).fetchSnapshot(at: now, calendar: utc)
        #expect(Set(snapshot.opened.map(\.id)).count == 800)
        #expect(Set(snapshot.merged.map(\.id)).count == 800)
        #expect(await overlap.requests == 1 + 9 + 9)
        // More than one page of each search at a time, and never more than the limit.
        #expect(await overlap.peak > 2)
        #expect(await overlap.peak <= 2 * GitHubClient.concurrentPages)
    }

    @Test func followsCursorsItCantNumberOnePageAtATime() async throws {
        let prs = (0..<800).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 3000)) }
        let overlap = Overlap()
        let fake = FakeGitHub(prs: prs, opaqueCursors: true)
        let snapshot = try await client(fake, overlap: overlap).fetchSnapshot(at: now, calendar: utc)
        #expect(Set(snapshot.opened.map(\.id)).count == 800)
        #expect(await overlap.requests == 1 + 8 + 1)
        #expect(await overlap.peak <= 2)
    }

    @Test func aPullRequestOpenedMidRefreshDoesNotPushAnotherOutOfTheCount() async throws {
        let prs = (0..<200).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 3000)) }
        let arrivals = (200..<210).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 3000)) }
        let fake = FakeGitHub(prs: prs, arrivals: arrivals)
        let snapshot = try await client(fake).fetchSnapshot(at: now, calendar: utc)
        #expect(Set(prs.map(\.id)).isSubset(of: snapshot.opened.map(\.id)))
        #expect(Set(snapshot.opened.map(\.id)).count == snapshot.opened.count)
    }

    @Test func aPullRequestOpenedBetweenPagesAnsweredOutOfOrderDoesNotPushAnotherOutOfTheCount() async throws {
        let prs = (0..<450).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 3000)) }
        let arrivals = (450..<460).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 3000)) }
        // Listed among the results on page 100, so nothing is seen twice and only the count gives the shift away.
        let fake = FakeGitHub(prs: prs, arrivals: arrivals, arrivalPosition: 150, arriveAfter: 190)
        let snapshot = try await clientAnsweringOutOfOrder(fake).fetchSnapshot(at: now, calendar: utc)
        #expect(Set(prs.map(\.id)).isSubset(of: snapshot.opened.map(\.id)))
    }

    @Test func oneArrivingAsAnotherLeavesBetweenPagesAnsweredOutOfOrderDoesNotPushAThirdOut() async throws {
        // The count stays at 300, so only a PR seen twice gives the shift away.
        let prs = (0..<300).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 3000)) }
        let arrival = pr(300, createdAt: monthStart.addingTimeInterval(300 * 3000))
        let fake = FakeGitHub(prs: prs, arrivals: [arrival], departures: ["PR_250"], arriveAfter: 190)
        let snapshot = try await clientAnsweringOutOfOrder(fake).fetchSnapshot(at: now, calendar: utc)
        #expect(Set(prs.map(\.id)).subtracting(["PR_250"]).isSubset(of: snapshot.opened.map(\.id)))
    }

    @Test func oneLeavingAsAnotherArrivesOnAPageAnsweredLateDoesNotPushAThirdOut() async throws {
        // The count stays at 300 and no PR is seen twice, so neither gives the shift away.
        let prs = (0..<300).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 3000)) }
        let arrival = pr(300, createdAt: monthStart.addingTimeInterval(300 * 3000))
        let fake = FakeGitHub(
            prs: prs, arrivals: [arrival], arrivalPosition: 150, departures: ["PR_250"], arriveAfter: 190
        )
        let snapshot = try await clientAnsweringOutOfOrder(fake).fetchSnapshot(at: now, calendar: utc)
        #expect(Set(prs.map(\.id)).subtracting(["PR_250"]).isSubset(of: snapshot.opened.map(\.id)))
    }

    @Test func pullRequestsLeavingFromTheFirstPageWhilePagesAreOutDoNotPushOthersPastIt() async throws {
        // A deleted repository takes twelve PRs off the first page, so every count-based cursor is out of date.
        let prs = (0..<211).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 3000)) }
        let gone = Set((48..<60).map { "PR_\($0)" })
        let fake = FakeGitHub(prs: prs, departures: gone, arriveAfter: 190)
        let snapshot = try await clientAnsweringOutOfOrder(fake).fetchSnapshot(at: now, calendar: utc)
        #expect(Set(snapshot.opened.map(\.id)) == Set(prs.map(\.id)).subtracting(gone))
    }

    @Test func pagesThatStillJoinUpKeepFollowingResultsListedAfterTheLast() async throws {
        // 150 PRs listed after the 200 already there move nothing, so the pages are kept and the rest followed.
        let prs = (0..<200).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 3000)) }
        let arrivals = (200..<350).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 3000)) }
        let overlap = Overlap()
        let fake = FakeGitHub(prs: prs, arrivals: arrivals, arrivalPosition: 200)
        let snapshot = try await client(fake, overlap: overlap).fetchSnapshot(at: now, calendar: utc)
        #expect(Set(snapshot.opened.map(\.id)).count == 350)
        #expect(await overlap.requests == 1 + (1 + 2 + 1) + 1)
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

    @Test func saysWhetherTheTokenWasSavedOrReadFromTheCLI() async {
        #expect(await TokenProvider(override: { "saved" }, cli: { "cli" }).credential()?.source == .saved)
        #expect(await TokenProvider(override: { nil }, cli: { "cli" }).credential()?.source == .githubCLI)
    }

    @Test func reportsNoTokenWhenNeitherSourceHasOne() async {
        let provider = TokenProvider(override: { nil }, cli: { nil })
        #expect(await provider.token() == nil)
    }

    @Test func blamesAMissingLoginOnlyWhenTheGitHubCLIIsInstalled() async {
        let loggedOut = TokenProvider(
            override: { nil }, cli: { nil }, cliInstalled: { true },
            lifetime: .seconds(60), retryFloor: .seconds(10), now: { .now }
        )
        #expect(await loggedOut.missingLogin() == .noToken)
        let uninstalled = TokenProvider(
            override: { nil }, cli: { nil }, cliInstalled: { false },
            lifetime: .seconds(60), retryFloor: .seconds(10), now: { .now }
        )
        #expect(await uninstalled.missingLogin() == .noGitHubCLI)
    }

    @Test func aMissingGitHubCLISaysToAddATokenInsteadOfLoggingIn() {
        let message = GitHubError.noGitHubCLI.localizedDescription
        #expect(message.contains("Add a token in Settings"))
        #expect(!message.contains("gh auth login"))
    }

    /// A provider whose CLI answers from `reads` in turn (repeating the last), on a clock the test moves.
    private func provider(reads: Counter, _ answers: [String?], clock: TestUptime) -> TokenProvider {
        TokenProvider(
            override: { nil },
            cli: { answers[min(reads.next(), answers.count) - 1] },
            lifetime: .seconds(60),
            retryFloor: .seconds(10),
            now: { clock.now }
        )
    }

    @Test func reusesTheCLITokenWithinItsLifetime() async {
        let reads = Counter()
        let clock = TestUptime()
        let provider = provider(reads: reads, ["first", "second"], clock: clock)
        #expect(await provider.token() == "first")
        clock.advance(.seconds(59))
        #expect(await provider.token() == "first")
        #expect(reads.count == 1)
    }

    @Test func picksUpAnotherGitHubAccountOnceTheLifetimeEnds() async {
        let reads = Counter()
        let clock = TestUptime()
        let provider = provider(reads: reads, ["work", "personal"], clock: clock)
        #expect(await provider.token() == "work")
        clock.advance(.seconds(60))
        #expect(await provider.token() == "personal")
    }

    @Test func aFailedReadKeepsTheWorkingToken() async {
        let reads = Counter()
        let clock = TestUptime()
        let provider = provider(reads: reads, ["work", nil, nil, "work"], clock: clock)
        #expect(await provider.token() == "work")
        clock.advance(.seconds(60))
        #expect(await provider.token() == "work")
        clock.advance(.seconds(60))
        #expect(await provider.token() == "work")
        clock.advance(.seconds(60))
        #expect(await provider.token() == "work")
        #expect(reads.count == 4)
    }

    @Test func doesNotRespawnTheCLIRightAfterAFailedRead() async {
        let reads = Counter()
        let clock = TestUptime()
        let provider = provider(reads: reads, ["work", nil, "switched"], clock: clock)
        #expect(await provider.token() == "work")
        clock.advance(.seconds(60))
        for _ in 0..<5 { #expect(await provider.token() == "work") }
        #expect(reads.count == 2)
        clock.advance(.seconds(10))
        #expect(await provider.token() == "switched")
        #expect(reads.count == 3)
    }

    @Test func dropsTheCLITokenAfterRepeatedFailuresMeanLogout() async {
        let reads = Counter()
        let clock = TestUptime()
        let provider = provider(reads: reads, ["work", nil], clock: clock)
        #expect(await provider.token() == "work")
        for _ in 0..<2 {
            clock.advance(.seconds(60))
            #expect(await provider.token() == "work")
        }
        clock.advance(.seconds(60))
        #expect(await provider.token() == nil)
    }

    @Test func aFailureStreakStartsOverAfterASuccessfulRead() async {
        let reads = Counter()
        let clock = TestUptime()
        let provider = provider(reads: reads, ["work", nil, nil, "work", nil, nil], clock: clock)
        for _ in 0..<6 {
            #expect(await provider.token() == "work")
            clock.advance(.seconds(60))
        }
    }

    @Test func aMissingLoginIsRetriedNoSoonerThanTheFloor() async {
        let reads = Counter()
        let clock = TestUptime()
        let provider = provider(reads: reads, [nil, "logged in"], clock: clock)
        for _ in 0..<4 { #expect(await provider.token() == nil) }
        #expect(reads.count == 1)
        clock.advance(.seconds(10))
        #expect(await provider.token() == "logged in")
    }

    @Test func invalidatingForcesAnImmediateReread() async {
        let reads = Counter()
        let clock = TestUptime()
        let provider = provider(reads: reads, ["stale", "fresh"], clock: clock)
        #expect(await provider.token() == "stale")
        await provider.invalidate()
        #expect(await provider.token() == "fresh")
    }

    @Test func aSavedTokenWinsWithoutTouchingTheCLI() async {
        let reads = Counter()
        let provider = TokenProvider(
            override: { "saved" }, cli: { "cli\(reads.next())" },
            lifetime: .seconds(60), retryFloor: .seconds(10), now: { .now }
        )
        #expect(await provider.token() == "saved")
        #expect(reads.count == 0)
    }

    @Test func runReturnsTrimmedOutputAndHandlesFailure() {
        #expect(GitHubCLI.run("/bin/echo", arguments: ["hi"]) == "hi")
        #expect(GitHubCLI.run("/usr/bin/false", arguments: []) == nil)
        #expect(GitHubCLI.run("/nonexistent/gh", arguments: []) == nil)
    }

    @Test func runGivesUpOnAStuckCommand() {
        #expect(GitHubCLI.run("/bin/sleep", arguments: ["30"], timeout: 0.2) == nil)
    }

    @Test func looksForTheGitHubCLIWhereverAPackageManagerPutsIt() {
        let paths = GitHubCLI.searchPaths(home: "/Users/sam", user: "sam")
        // The places looked before the rest were added, in the same order, so nobody gets a different `gh`.
        #expect(paths.prefix(3) == ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"])
        for path in [
            "/opt/local/bin/gh", "/Users/sam/.nix-profile/bin/gh", "/etc/profiles/per-user/sam/bin/gh",
            "/run/current-system/sw/bin/gh", "/Users/sam/.local/bin/gh",
        ] {
            #expect(paths.contains(path))
        }
    }

    @Test func usesTheFirstGitHubCLIThatCanRun() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "github-data-r3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let notRunnable = folder.appending(path: "plain").path, runnable = folder.appending(path: "gh").path
        FileManager.default.createFile(atPath: notRunnable, contents: Data())
        FileManager.default.createFile(atPath: runnable, contents: Data(), attributes: [.posixPermissions: 0o755])
        let missing = folder.appending(path: "missing").path
        #expect(GitHubCLI.executablePath(in: [missing, notRunnable, runnable]) == runnable)
        #expect(GitHubCLI.executablePath(in: [missing, notRunnable]) == nil)
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

/// Answers requests from a real `URLSession`, so tests see what GitHub's status codes and headers do.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Response = (status: Int, headers: [String: String], body: Data)

    /// Each stub is found through the request's token, so suites can run in parallel.
    private nonisolated(unsafe) static var stubs: [String: @Sendable (Data) throws -> Response] = [:]
    private static let lock = NSLock()

    static func register(_ token: String, _ stub: @escaping @Sendable (Data) throws -> Response) {
        lock.withLock { stubs[token] = stub }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let token = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "bearer ", with: "")
        let stub = Self.lock.withLock { Self.stubs[token] }
        do {
            let response = try stub!(requestBody())
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: response.headers
                )!,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    /// URLSession hands protocols the body as a stream.
    private func requestBody() -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Counts one more and returns the new total.
    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    var count: Int { lock.withLock { value } }
}

private final class TokenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    func add(_ token: String) { lock.withLock { if !seen.contains(token) { seen.append(token) } } }

    /// Distinct tokens, in the order first used.
    var tokens: [String] { lock.withLock { seen } }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// A monotonic clock the test moves by hand.
private final class TestUptime: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var elapsed = Duration.zero

    var now: ContinuousClock.Instant { lock.withLock { start + elapsed } }
    func advance(_ by: Duration) { lock.withLock { elapsed += by } }
}

/// A header value and how long the client should wait because of it.
private struct HeaderCase: Sendable, CustomTestStringConvertible {
    let value: String
    let wait: TimeInterval
    init(_ value: String, _ wait: TimeInterval) { (self.value, self.wait) = (value, wait) }
    var testDescription: String { "\(value.prefix(40)) -> \(wait)s" }
}

@Suite struct GitHubHTTPTests {
    private func http(
        clock: TestClock = TestClock(now), retryDelays: [Duration] = [.zero, .zero],
        _ stub: @escaping @Sendable (Data) throws -> StubURLProtocol.Response
    ) -> GitHubClient {
        let token = UUID().uuidString
        StubURLProtocol.register(token, stub)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return GitHubClient(
            tokens: TokenProvider(override: { token }, cli: { nil }),
            session: URLSession(configuration: configuration),
            retryDelays: retryDelays,
            now: { clock.now }
        )
    }

    private func ok(_ fake: FakeGitHub, _ body: Data) throws -> StubURLProtocol.Response {
        (200, [:], try fake.respond(to: body))
    }

    private func rateLimited(_ error: Error) -> Date? {
        if case GitHubError.rateLimited(let until) = error { return until }
        return nil
    }

    private func failure(of client: GitHubClient) async -> Error? {
        do {
            _ = try await client.fetchSnapshot(at: now, calendar: utc)
            return nil
        } catch {
            return error
        }
    }

    /// A client whose tokens come from a `TokenProvider` that reads `answers` in turn, one token per read.
    private func clientReading(
        _ answers: [String?], clock: TestUptime, reads: Counter,
        _ stub: @escaping @Sendable (String, Data) throws -> StubURLProtocol.Response
    ) -> GitHubClient {
        for token in answers.compactMap({ $0 }) {
            StubURLProtocol.register(token) { body in try stub(token, body) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let provider = TokenProvider(
            override: { nil },
            cli: { answers[min(reads.next(), answers.count) - 1] },
            lifetime: .seconds(60), retryFloor: .seconds(10), now: { clock.now }
        )
        return GitHubClient(
            tokens: provider, session: URLSession(configuration: configuration),
            retryDelays: [.zero, .zero], now: { now }
        )
    }

    @Test func aRefreshUsesOneTokenEvenIfItOutlastsTheLifetime() async throws {
        let fake = FakeGitHub(prs: (0..<250).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 60)) })
        let clock = TestUptime()
        let reads = Counter()
        let used = TokenLog()
        let first = "tok-\(UUID().uuidString)", second = "tok-\(UUID().uuidString)"
        let client = clientReading([first, second], clock: clock, reads: reads) { token, body in
            used.add(token)
            // Each request takes long enough that the cached token would expire several times.
            clock.advance(.seconds(45))
            return try ok(fake, body)
        }
        let snapshot = try await client.fetchSnapshot(at: now, calendar: utc)
        #expect(snapshot.count(for: .opened) == 250)
        #expect(used.tokens == [first])
        #expect(reads.count == 1)
    }

    @Test func aTransientCLIFailureDoesNotFailTheRefresh() async throws {
        let fake = FakeGitHub(prs: (0..<250).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 60)) })
        let clock = TestUptime()
        let reads = Counter()
        let token = "tok-\(UUID().uuidString)"
        let client = clientReading([token, nil], clock: clock, reads: reads) { _, body in try ok(fake, body) }
        _ = try await client.fetchSnapshot(at: now, calendar: utc)
        clock.advance(.seconds(15 * 60))
        // The CLI fails on this refresh's read, but the login is fine.
        let snapshot = try await client.fetchSnapshot(at: now, calendar: utc)
        #expect(snapshot.count(for: .opened) == 250)
        #expect(reads.count == 2)
    }

    @Test func aRejectedTokenFailsTheRefreshAndIsReadAgainNextTime() async throws {
        let fake = FakeGitHub(prs: [pr(1, createdAt: monthStart)])
        let clock = TestUptime()
        let reads = Counter()
        let stale = "tok-\(UUID().uuidString)", fresh = "tok-\(UUID().uuidString)"
        let client = clientReading([stale, fresh], clock: clock, reads: reads) { token, body in
            token == stale ? (401, [:], Data()) : try ok(fake, body)
        }
        #expect(await failure(of: client) as? GitHubError == .unauthorized(.githubCLI))
        // No clock movement: the 401 alone must force the re-read.
        let snapshot = try await client.fetchSnapshot(at: now, calendar: utc)
        #expect(snapshot.count(for: .opened) == 1)
    }

    @Test func aBriefServerErrorDoesNotRestartTheFetch() async throws {
        // Three pages of opened PRs; the request for one of them fails twice.
        let fake = FakeGitHub(prs: (0..<250).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 60)) })
        let requests = Counter()
        let failures = Counter()
        let client = http { body in
            _ = requests.next()
            if String(decoding: body, as: UTF8.self).contains(GitHubClient.cursor(at: 99)), failures.next() <= 2 {
                return (502, [:], Data("bad gateway".utf8))
            }
            return try ok(fake, body)
        }
        let snapshot = try await client.fetchSnapshot(at: now, calendar: utc)
        #expect(snapshot.count(for: .opened) == 250)
        // Viewer, three opened pages, one empty merged page, and two retries of the failed page.
        #expect(requests.count == 7)
    }

    @Test func aDroppedConnectionIsRetried() async throws {
        let fake = FakeGitHub(prs: [pr(1, createdAt: monthStart)])
        let attempts = Counter()
        let client = http { body in
            if attempts.next() == 1 { throw URLError(.networkConnectionLost) }
            return try ok(fake, body)
        }
        let snapshot = try await client.fetchSnapshot(at: now, calendar: utc)
        #expect(snapshot.count(for: .opened) == 1)
    }

    @Test func aServerErrorThatPersistsIsReportedAfterTheRetriesRunOut() async {
        let requests = Counter()
        let client = http { _ in
            _ = requests.next()
            return (503, [:], Data())
        }
        let error = await failure(of: client)
        #expect(error as? GitHubError == .http(503))
        #expect(requests.count == 3)
    }

    @Test func aRejectedRequestIsNotRetried() async {
        let requests = Counter()
        let client = http { _ in
            _ = requests.next()
            return (404, [:], Data())
        }
        let error = await failure(of: client)
        #expect(error as? GitHubError == .http(404))
        #expect(requests.count == 1)
    }

    @Test func aRejectedTokenIsNotRetried() async {
        let requests = Counter()
        let client = http { _ in
            _ = requests.next()
            return (401, [:], Data())
        }
        let error = await failure(of: client)
        #expect(error as? GitHubError == .unauthorized(.saved))
        #expect(requests.count == 1)
    }

    @Test func aRejectedSavedTokenIsBlamedEvenWhenTheGitHubCLIIsLoggedIn() async {
        let fake = FakeGitHub(prs: [pr(1, createdAt: monthStart)])
        let saved = "tok-\(UUID().uuidString)", cli = "tok-\(UUID().uuidString)"
        StubURLProtocol.register(saved) { _ in (401, [:], Data(#"{"message":"Bad credentials"}"#.utf8)) }
        StubURLProtocol.register(cli) { body in try ok(fake, body) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = GitHubClient(
            tokens: TokenProvider(override: { saved }, cli: { cli }),
            session: URLSession(configuration: configuration), retryDelays: [], now: { now }
        )
        // The saved token wins over `gh`, so logging in to `gh` again would change nothing.
        #expect(await failure(of: client) as? GitHubError == .unauthorized(.saved))
    }

    @Test(arguments: [true, false])
    func aRefreshWithNoLoginSaysWhetherTheGitHubCLIIsThere(installed: Bool) async {
        let client = GitHubClient(
            tokens: TokenProvider(
                override: { nil }, cli: { nil }, cliInstalled: { installed },
                lifetime: .seconds(60), retryFloor: .seconds(10), now: { .now }
            ),
            session: .shared, retryDelays: [], now: { now }
        )
        #expect(await failure(of: client) as? GitHubError == (installed ? .noToken : .noGitHubCLI))
    }

    @Test func aSavedTokenWorksWithoutTheGitHubCLI() async throws {
        let fake = FakeGitHub(prs: [pr(1, createdAt: monthStart)])
        let saved = "tok-\(UUID().uuidString)"
        StubURLProtocol.register(saved) { body in try ok(fake, body) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = GitHubClient(
            tokens: TokenProvider(
                override: { saved }, cli: { nil }, cliInstalled: { false },
                lifetime: .seconds(60), retryFloor: .seconds(10), now: { .now }
            ),
            session: URLSession(configuration: configuration), retryDelays: [], now: { now }
        )
        let snapshot = try await client.fetchSnapshot(at: now, calendar: utc)
        #expect(snapshot.count(for: .opened) == 1)
    }

    @Test func aRejectedTokenSaysHowToReplaceThatToken() {
        let saved = GitHubError.unauthorized(.saved).localizedDescription
        #expect(saved.contains("token saved in Settings"))
        #expect(!saved.contains("gh auth login"))
        let cli = GitHubError.unauthorized(.githubCLI).localizedDescription
        #expect(cli.contains("`gh` login"))
        #expect(cli.contains("Run `gh auth login`"))
    }

    @Test func aPlainForbiddenIsNotARateLimit() async {
        let client = http { _ in (403, [:], Data(#"{"message":"Resource not accessible"}"#.utf8)) }
        let error = await failure(of: client)
        #expect(error as? GitHubError == .http(403, message: "Resource not accessible"))
    }

    @Test func aRefusalSaysWhatGitHubSaid() async throws {
        let message = "Although you appear to have the correct authorization credentials, the `acme` organization has an IP allow list enabled, and your IP address is not permitted to access this resource."
        let client = http { _ in (403, [:], Data(#"{"message":"\#(message)","documentation_url":"https://docs.github.com"}"#.utf8)) }
        let description = try #require(await failure(of: client)?.localizedDescription)
        #expect(description == "GitHub returned HTTP 403: \(message)")
    }

    @Test func aServerErrorKeepsGitHubsExplanationAfterTheRetriesRunOut() async {
        let requests = Counter()
        let message = "Something went wrong while executing your query. This may be the result of a timeout, or it could be a GitHub bug."
        let client = http { _ in
            _ = requests.next()
            return (502, [:], Data(#"{"data":null,"errors":[{"message":"\#(message)"}]}"#.utf8))
        }
        #expect(await failure(of: client) as? GitHubError == .http(502, message: message))
        #expect(requests.count == 3)
    }

    @Test(arguments: ["<html><body>Forbidden by policy</body></html>", "", #"{"message":"  "}"#])
    func aRefusalWithNothingToSayGivesOnlyTheStatus(body: String) async {
        let client = http { _ in (403, [:], Data(body.utf8)) }
        let error = await failure(of: client)
        #expect(error as? GitHubError == .http(403))
        #expect(error?.localizedDescription == "GitHub returned HTTP 403.")
    }

    @Test(arguments: ["<html><body>Access to this site is blocked by your network administrator.</body></html>", ""])
    func aReplyThatIsNotJSONSaysSomethingElseAnswered(body: String) async {
        let requests = Counter()
        let client = http { _ in
            _ = requests.next()
            return (200, [:], Data(body.utf8))
        }
        let error = await failure(of: client)
        #expect(error as? GitHubError == .notGitHub)
        #expect(error?.localizedDescription.contains("network filter or proxy") == true)
        // A filter's page doesn't go away in a few seconds.
        #expect(requests.count == 1)
    }

    @Test func aJSONReplyOfTheWrongShapeIsNotBlamedOnTheNetwork() async {
        let client = http { _ in (200, [:], Data(#"{"data":{"viewer":null}}"#.utf8)) }
        let error = await failure(of: client)
        #expect(error is DecodingError)
    }

    @Test func secondaryLimitWaitsForRetryAfter() async {
        let client = http { _ in
            (403, ["Retry-After": "120"], Data(#"{"message":"You have exceeded a secondary rate limit."}"#.utf8))
        }
        let error = await failure(of: client)
        #expect(error as? GitHubError == .rateLimited(until: now.addingTimeInterval(120)))
    }

    @Test func secondaryLimitWithNoHeadersWaitsAMinute() async {
        let client = http { _ in (403, [:], Data(#"{"message":"You have exceeded a secondary rate limit."}"#.utf8)) }
        let error = await failure(of: client)
        #expect(error as? GitHubError == .rateLimited(until: now.addingTimeInterval(60)))
    }

    @Test func tooManyRequestsIsARateLimit() async {
        let client = http { _ in (429, [:], Data()) }
        let error = await failure(of: client)
        #expect(error as? GitHubError == .rateLimited(until: now.addingTimeInterval(60)))
    }

    @Test func exhaustedBudgetWaitsForTheReset() async {
        let reset = now.addingTimeInterval(1800)
        let headers = ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))]
        let client = http { _ in (403, headers, Data()) }
        let error = await failure(of: client)
        #expect(error as? GitHubError == .rateLimited(until: reset))
    }

    @Test func graphQLRateLimitInASuccessfulResponseWaitsForTheReset() async {
        let reset = now.addingTimeInterval(1800)
        let headers = ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))]
        let body = Data(#"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded for user ID 1."}]}"#.utf8)
        let client = http { _ in (200, headers, body) }
        let error = await failure(of: client)
        #expect(error as? GitHubError == .rateLimited(until: reset))
    }

    @Test func theLastRequestInTheBudgetStillSucceeds() async throws {
        let fake = FakeGitHub(prs: [pr(1, createdAt: monthStart)])
        let client = http { body in
            (200, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1893456000"], try fake.respond(to: body))
        }
        let snapshot = try await client.fetchSnapshot(at: now, calendar: utc)
        #expect(snapshot.count(for: .opened) == 1)
    }

    @Test func staysOffTheNetworkUntilTheLimitLifts() async throws {
        let clock = TestClock(now)
        let fake = FakeGitHub(prs: [pr(1, createdAt: monthStart)])
        let requests = Counter()
        let client = http(clock: clock) { body in
            if requests.next() == 1 { return (429, ["Retry-After": "120"], Data()) }
            return try ok(fake, body)
        }

        let lifts = now.addingTimeInterval(120)
        for _ in 0..<3 {
            let error = await failure(of: client)
            #expect(error as? GitHubError == .rateLimited(until: lifts))
        }
        #expect(requests.count == 1)

        clock.now = lifts
        let snapshot = try await client.fetchSnapshot(at: now, calendar: utc)
        #expect(snapshot.count(for: .opened) == 1)
    }

    /// The first request is limited by `limit`. The error must name `expected`, and the gate must be
    /// open again at that moment.
    private func expectLimit(
        _ limit: StubURLProtocol.Response, until expected: Date, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let clock = TestClock(now)
        let fake = FakeGitHub(prs: [pr(1, createdAt: monthStart)])
        let requests = Counter()
        let client = http(clock: clock) { body in
            if requests.next() == 1 { return limit }
            return try ok(fake, body)
        }
        let error = await failure(of: client)
        #expect(error as? GitHubError == .rateLimited(until: expected), sourceLocation: sourceLocation)
        clock.now = expected
        let snapshot = try await client.fetchSnapshot(at: now, calendar: utc)
        #expect(snapshot.count(for: .opened) == 1, sourceLocation: sourceLocation)
    }

    @Test(arguments: [
        HeaderCase("120", 120),
        HeaderCase("99999999999", 3660),
        HeaderCase("1" + String(repeating: "0", count: 400), 60),
        HeaderCase("1e308", 60), HeaderCase("inf", 60), HeaderCase("nan", 60), HeaderCase("-500", 60),
        HeaderCase("0", 60), HeaderCase("1.5", 60), HeaderCase("soon", 60),
        HeaderCase("Wed, 21 Oct 2037 07:28:00 GMT", 60),
    ])
    fileprivate func retryAfterIsReadStrictlyAndCapped(header: HeaderCase) async throws {
        try await expectLimit((429, ["Retry-After": header.value], Data()), until: now.addingTimeInterval(header.wait))
    }

    @Test func aWholeHourRetryAfterIsHonored() async throws {
        try await expectLimit((429, ["Retry-After": "3600"], Data()), until: now.addingTimeInterval(3600))
    }

    @Test func aSecondaryLimitIsCappedToo() async throws {
        let body = Data(#"{"message":"You have exceeded a secondary rate limit."}"#.utf8)
        try await expectLimit((403, ["Retry-After": "99999999999"], body), until: now.addingTimeInterval(3660))
    }

    @Test(arguments: [
        HeaderCase(String(Int(now.addingTimeInterval(100 * 365 * 86400).timeIntervalSince1970)), 3660),
        HeaderCase(String(Int(now.addingTimeInterval(1800).timeIntervalSince1970 * 1000)), 3660),
        HeaderCase(String(Int(now.addingTimeInterval(-60).timeIntervalSince1970)), 60),
        HeaderCase("inf", 60), HeaderCase("nan", 60), HeaderCase("1e308", 60), HeaderCase("-1", 60),
        HeaderCase("garbage", 60),
    ])
    fileprivate func aResetIsCappedAndGarbageFallsBackToAMinute(reset: HeaderCase) async throws {
        let headers = ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset.value]
        try await expectLimit((403, headers, Data()), until: now.addingTimeInterval(reset.wait))
    }

    /// A client whose saved token can be changed between refreshes, as Settings or `gh auth switch` would.
    private func clientSwitching(
        from first: String, clock: TestClock = TestClock(now),
        _ stub: @escaping @Sendable (String, Data) throws -> StubURLProtocol.Response
    ) -> (client: GitHubClient, use: @Sendable (String) -> Void) {
        let current = Box(first)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = GitHubClient(
            tokens: TokenProvider(override: { current.value }, cli: { nil }),
            session: URLSession(configuration: configuration),
            retryDelays: [.zero, .zero], now: { clock.now }
        )
        return (client, { token in
            StubURLProtocol.register(token) { body in try stub(token, body) }
            current.value = token
        })
    }

    @Test func aDifferentTokenIsNotHeldBackByAnotherTokensLimit() async throws {
        let fake = FakeGitHub(prs: [pr(1, createdAt: monthStart)])
        let requests = Counter()
        let limited = "tok-\(UUID().uuidString)", other = "tok-\(UUID().uuidString)"
        let (client, use) = clientSwitching(from: limited) { token, body in
            requests.next()
            return token == limited ? (429, ["Retry-After": "1800"], Data()) : try ok(fake, body)
        }
        use(limited)
        let until = now.addingTimeInterval(1800)
        #expect(await failure(of: client) as? GitHubError == .rateLimited(until: until))
        #expect(requests.count == 1)

        use(other)
        let snapshot = try await client.fetchSnapshot(at: now, calendar: utc)
        #expect(snapshot.count(for: .opened) == 1)

        // Going back to the limited token finds its limit still standing, without another request.
        let before = requests.count
        use(limited)
        #expect(await failure(of: client) as? GitHubError == .rateLimited(until: until))
        #expect(requests.count == before)
    }

    @Test func aClockMovedBackDoesNotKeepTheGateClosed() async throws {
        let clock = TestClock(now)
        let fake = FakeGitHub(prs: [pr(1, createdAt: monthStart)])
        let requests = Counter()
        let client = http(clock: clock) { body in
            if requests.next() == 1 { return (429, [:], Data()) }
            return try ok(fake, body)
        }
        let until = now.addingTimeInterval(60)
        #expect(await failure(of: client) as? GitHubError == .rateLimited(until: until))

        // A small step back is still within a possible wait, so the limit stands.
        clock.now = now.addingTimeInterval(-10)
        #expect(await failure(of: client) as? GitHubError == .rateLimited(until: until))
        #expect(requests.count == 1)

        // A step back of a day can't be a wait GitHub asked for.
        clock.now = now.addingTimeInterval(-86400)
        let snapshot = try await client.fetchSnapshot(at: now, calendar: utc)
        #expect(snapshot.count(for: .opened) == 1)
    }

    @Test(arguments: [
        "You can change the org rate limit settings in your organization.",
        "Resource not accessible by personal access token: cannot generate limited tokens.",
        "Repository 'octo/rate limiter' is archived.",
    ])
    func aForbiddenMessageThatOnlyMentionsLimitsIsNotARateLimit(message: String) async {
        let requests = Counter()
        let body = Data(#"{"message":"\#(message)"}"#.utf8)
        let client = http { _ in
            _ = requests.next()
            return (403, ["X-RateLimit-Remaining": "4000"], body)
        }
        for _ in 0..<2 { #expect(await failure(of: client) as? GitHubError == .http(403, message: message)) }
        #expect(requests.count == 2)
    }

    @Test func aSingleSignOnForbiddenOnTheLastRequestOfTheBudgetIsNotARateLimit() async {
        let requests = Counter()
        let reset = String(Int(now.addingTimeInterval(1800).timeIntervalSince1970))
        let message = "Resource protected by organization SAML enforcement. You must grant your Personal Access token access to this organization."
        let body = Data(#"{"message":"\#(message)"}"#.utf8)
        let client = http { _ in
            _ = requests.next()
            return (403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset], body)
        }
        for _ in 0..<2 { #expect(await failure(of: client) as? GitHubError == .http(403, message: message)) }
        #expect(requests.count == 2)
    }

    /// Messages a 403 limit might carry. The first two are abuse detection wording; the rest are
    /// not wording the client recognises, so only a header can tell they are limits.
    private static let abuse = [
        "You have triggered an abuse detection mechanism and have been temporarily blocked from content creation. Please retry your request again later.",
        "You have triggered an abuse detection mechanism. Please wait a few minutes before you try again.",
    ]
    private static let unrecognised = ["Rate limit exceeded", "Too many requests", "You have exceeded the rate limit", "Forbidden"]

    private func forbidden(_ message: String, _ headers: [String: String]) -> StubURLProtocol.Response {
        (403, headers, Data(#"{"message":"\#(message)"}"#.utf8))
    }

    @Test(arguments: abuse + unrecognised)
    func aForbiddenWithRetryAfterIsALimitWhateverItsMessageSays(message: String) async throws {
        try await expectLimit(forbidden(message, ["Retry-After": "60"]), until: now.addingTimeInterval(60))
        try await expectLimit(forbidden(message, ["Retry-After": "3600", "X-RateLimit-Remaining": "4000"]), until: now.addingTimeInterval(3600))
    }

    @Test(arguments: abuse)
    func abuseDetectionIsALimitWithoutAnyHeaders(message: String) async throws {
        try await expectLimit(forbidden(message, [:]), until: now.addingTimeInterval(60))
    }

    @Test(arguments: unrecognised)
    func aForbiddenWithUnrecognisedWordingAndNoHeaderIsNotALimit(message: String) async {
        let requests = Counter()
        let client = http { _ in
            _ = requests.next()
            return forbidden(message, ["X-RateLimit-Remaining": "4000"])
        }
        for _ in 0..<2 { #expect(await failure(of: client) as? GitHubError == .http(403, message: message)) }
        #expect(requests.count == 2)
    }

    @Test func aPlainForbiddenWithRetryAfterIsALimit() async throws {
        try await expectLimit((403, ["Retry-After": "3600", "X-RateLimit-Remaining": "4000"], Data()), until: now.addingTimeInterval(3600))
    }

    @Test(arguments: [
        HeaderCase("120", 120), HeaderCase("99999999999", 3660),
        HeaderCase("0", 60), HeaderCase("-500", 60), HeaderCase("1e308", 60), HeaderCase("inf", 60),
        HeaderCase("nan", 60), HeaderCase("soon", 60), HeaderCase("Wed, 21 Oct 2037 07:28:00 GMT", 60),
    ])
    fileprivate func aForbiddenRetryAfterIsALimitWhateverItsValueOrMessage(header: HeaderCase) async throws {
        let headers = ["Retry-After": header.value]
        try await expectLimit((403, headers, Data()), until: now.addingTimeInterval(header.wait))
        try await expectLimit(forbidden("Forbidden", headers), until: now.addingTimeInterval(header.wait))
    }

    @Test func aRateLimitTellsThePersonWhenItWillTryAgain() throws {
        let until = now.addingTimeInterval(120)
        let description = try #require(GitHubError.rateLimited(until: until).errorDescription)
        #expect(description.contains(until.formatted(date: .omitted, time: .shortened)))
    }
}

@Suite struct GitHubRetryTests {
    @Test func retriesAreLimitedAndAppliedToAnyTransport() async {
        let attempts = Counter()
        let client = GitHubClient(
            transport: { _ in
                _ = attempts.next()
                throw GitHubError.http(502)
            },
            retryDelays: [.zero, .zero]
        )
        await #expect(throws: GitHubError.http(502)) {
            _ = try await client.fetchSnapshot(at: now, calendar: utc)
        }
        #expect(attempts.count == 3)
    }

    @Test func cancellingDuringARetryWaitStopsTheFetch() async {
        let attempts = Counter()
        let client = GitHubClient(
            transport: { _ in
                _ = attempts.next()
                throw GitHubError.http(502)
            },
            retryDelays: [.seconds(60)]
        )
        let task = Task { try await client.fetchSnapshot(at: now, calendar: utc) }
        while attempts.count == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(attempts.count == 1)
    }
}
