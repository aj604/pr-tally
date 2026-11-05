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

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
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

    @Test func aBriefServerErrorDoesNotRestartTheFetch() async throws {
        // Three pages of opened PRs; the request for one of them fails twice.
        let fake = FakeGitHub(prs: (0..<250).map { pr($0, createdAt: monthStart.addingTimeInterval(Double($0) * 60)) })
        let requests = Counter()
        let failures = Counter()
        let client = http { body in
            _ = requests.next()
            if String(decoding: body, as: UTF8.self).contains("\"after\":\"100\""), failures.next() <= 2 {
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
        #expect(error as? GitHubError == .unauthorized)
        #expect(requests.count == 1)
    }

    @Test func aPlainForbiddenIsNotARateLimit() async {
        let client = http { _ in (403, [:], Data(#"{"message":"Resource not accessible"}"#.utf8)) }
        let error = await failure(of: client)
        #expect(error as? GitHubError == .http(403))
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
        for _ in 0..<2 { #expect(await failure(of: client) as? GitHubError == .http(403)) }
        #expect(requests.count == 2)
    }

    @Test func aSingleSignOnForbiddenOnTheLastRequestOfTheBudgetIsNotARateLimit() async {
        let requests = Counter()
        let reset = String(Int(now.addingTimeInterval(1800).timeIntervalSince1970))
        let body = Data(
            #"{"message":"Resource protected by organization SAML enforcement. You must grant your Personal Access token access to this organization."}"#
                .utf8)
        let client = http { _ in
            _ = requests.next()
            return (403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset, "Retry-After": "120"], body)
        }
        for _ in 0..<2 { #expect(await failure(of: client) as? GitHubError == .http(403)) }
        #expect(requests.count == 2)
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
