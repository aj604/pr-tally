import Foundation

public enum GitHubError: Error, Equatable, LocalizedError {
    case noToken
    /// No saved token, and no `gh` CLI to ask for a login.
    case noGitHubCLI
    case unauthorized(TokenSource)
    /// A status GitHub doesn't answer queries with, and what GitHub said about it, if anything.
    case http(Int, message: String? = nil)
    case graphQL(String)
    case rateLimited(until: Date)
    /// A reply that isn't JSON, which GitHub's API never sends.
    case notGitHub

    public var errorDescription: String? {
        switch self {
        case .noToken: "No GitHub login found. Run `gh auth login` or add a token in Settings."
        case .noGitHubCLI:
            "No GitHub login found, and the `gh` CLI isn't installed where PRTally looks "
                + "(Homebrew, MacPorts, Nix or ~/.local/bin). Add a token in Settings."
        case .unauthorized(.saved):
            "GitHub rejected the token saved in Settings, which may have expired. "
                + "Save a new one there, or remove it to use your `gh` login."
        case .unauthorized(.githubCLI):
            "GitHub rejected your `gh` login. Run `gh auth login` to sign in again, or add a token in Settings."
        case .http(let code, nil): "GitHub returned HTTP \(code)."
        case .http(let code, let message?): "GitHub returned HTTP \(code): \(message)"
        case .graphQL(let message): "GitHub error: \(message)"
        case .rateLimited(let until):
            "GitHub rate limit reached. Trying again after \(until.formatted(date: .omitted, time: .shortened))."
        case .notGitHub:
            "Something other than GitHub answered, such as a network filter or proxy. "
                + "Check that github.com opens in your browser, then refresh."
        }
    }
}

/// Sends a GraphQL request body and returns the response body.
public typealias GraphQLTransport = @Sendable (Data) async throws -> Data

public struct GitHubClient: Sendable {
    /// GitHub search returns at most this many results per query, however many match.
    static let searchResultCap = 1000

    /// How many results each search page asks for, the most GitHub allows.
    static let pageSize = 100

    /// How many of one search's pages are asked for at once. Two searches run side by side, so a refresh
    /// has at most twice this many requests in flight.
    static let concurrentPages = 4

    /// How long to wait before each retry of a request that failed in passing.
    static let retryDelays: [Duration] = [.seconds(1), .seconds(3)]

    private let transport: GraphQLTransport
    private let retryDelays: [Duration]
    /// Readies the transport for one refresh, so every request in it shares one set of credentials.
    private let open: @Sendable () async throws -> GraphQLTransport

    public init(transport: @escaping GraphQLTransport) {
        self.init(transport: transport, retryDelays: Self.retryDelays)
    }

    init(transport: @escaping GraphQLTransport, retryDelays: [Duration]) {
        self.init(transport: transport, retryDelays: retryDelays, open: { transport })
    }

    private init(
        transport: @escaping GraphQLTransport, retryDelays: [Duration],
        open: @escaping @Sendable () async throws -> GraphQLTransport
    ) {
        self.transport = transport
        self.retryDelays = retryDelays
        self.open = open
    }

    /// A client that posts to api.github.com, asking `tokens` for credentials on each request.
    public init(tokens: TokenProvider, session: URLSession = .shared) {
        self.init(tokens: tokens, session: session, retryDelays: Self.retryDelays, now: { Date() })
    }

    init(tokens: TokenProvider, session: URLSession, retryDelays: [Duration], now: @escaping @Sendable () -> Date) {
        let gate = GitHubRateLimitGate()
        let open: @Sendable () async throws -> GraphQLTransport = {
            guard let (token, source) = await tokens.credential() else { throw await tokens.missingLogin() }
            try await gate.check(now: now(), token: token)
            return { body in
                try await gate.check(now: now(), token: token)
                var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
                request.httpMethod = "POST"
                request.httpBody = body
                request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("PRTally", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                if let response = response as? HTTPURLResponse,
                    let retry = GitHubRateLimit.retryDate(for: response, body: data, now: now())
                {
                    await gate.block(until: retry, token: token)
                    throw GitHubError.rateLimited(until: retry)
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 {
                    await tokens.invalidate()
                    throw GitHubError.unauthorized(source)
                }
                guard status == 200 else { throw GitHubError.http(status, message: GitHubClient.message(in: data)) }
                return data
            }
        }
        self.init(transport: { body in try await open()(body) }, retryDelays: retryDelays, open: open)
    }

    public func fetchSnapshot(at now: Date = Date(), calendar: Calendar = .current) async throws -> MonthSnapshot {
        // A refresh outlasting the token's lifetime must not switch accounts between pages.
        let pinned = GitHubClient(transport: try await open(), retryDelays: retryDelays)
        return try await pinned.fetch(at: now, calendar: calendar)
    }

    private func fetch(at now: Date, calendar: Calendar) async throws -> MonthSnapshot {
        let window = MonthWindow(containing: now, calendar: calendar)
        let viewer = try await fetchViewer(window: window)
        async let opened = pullRequests(login: viewer.login, qualifier: "created", window: window)
        async let merged = pullRequests(login: viewer.login, qualifier: "merged", window: window)
        return try await MonthSnapshot(
            login: viewer.login,
            window: window,
            opened: opened,
            merged: merged,
            totalContributions: viewer.contributionsCollection.contributionCalendar.totalContributions,
            fetchedAt: now
        )
    }

    private func fetchViewer(window: MonthWindow) async throws -> ViewerData.Viewer {
        let query = """
        query($from: DateTime!, $to: DateTime!) {
          viewer {
            login
            contributionsCollection(from: $from, to: $to) {
              contributionCalendar { totalContributions }
            }
          }
        }
        """
        let variables = ["from": Self.timestamp(window.start), "to": Self.timestamp(window.end)]
        let data: ViewerData = try await send(query: query, variables: variables)
        return data.viewer
    }

    private func pullRequests(login: String, qualifier: String, window: MonthWindow) async throws -> [PullRequest] {
        // Search ranges include both ends, so stop one second before next month.
        let all = try await search(
            login: login, qualifier: qualifier, from: window.start, to: window.end.addingTimeInterval(-1)
        )
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    /// Fetches a whole range, halving it whenever it matches more than search will return.
    private func search(login: String, qualifier: String, from: Date, to: Date) async throws -> [PullRequest] {
        let terms = "author:\(login) is:pr \(qualifier):\(Self.timestamp(from))..\(Self.timestamp(to))"
        var page = try await searchPage(query: terms, after: nil)

        if page.issueCount > Self.searchResultCap, to.timeIntervalSince(from) >= 2 {
            let middle = Date(timeIntervalSince1970: ((from.timeIntervalSince1970 + to.timeIntervalSince1970) / 2).rounded(.down))
            let first = try await search(login: login, qualifier: qualifier, from: from, to: middle)
            let second = try await search(
                login: login, qualifier: qualifier, from: middle.addingTimeInterval(1), to: to
            )
            return first + second
        }

        var results = page.nodes.compactMap { $0 }
        if page.pageInfo.hasNextPage, let cursors = Self.remainingCursors(after: page), !cursors.isEmpty {
            let rest = try await searchPages(query: terms, after: cursors)
            if Self.areJoined([page] + rest) {
                results += rest.flatMap { $0.nodes.dropFirst().compactMap { $0 } }
                page = rest[rest.count - 1]
            } else {
                // Results arrived or left while the pages were out, and moved where a page starts. Every cursor
                // is a count of results, so any of them can be stale now, the first page's included. Starting
                // over and following one page at a time only ever pushes results later, where the next page
                // finds them again.
                page = try await searchPage(query: terms, after: nil)
                results = page.nodes.compactMap { $0 }
            }
        }
        // Results arriving after the last page asked for, or cursors that couldn't be numbered.
        while page.pageInfo.hasNextPage, let cursor = page.pageInfo.endCursor {
            page = try await searchPage(query: terms, after: cursor)
            results += page.nodes.compactMap { $0 }
        }
        return results
    }

    /// Where each page after `first` starts, when `first`'s cursor shows GitHub's numbering: the count of
    /// results so far after `cursor:`, in base64. Each page starts at the one before's last result, so
    /// `areJoined` can tell whether anything moved between them. GitHub doesn't promise that numbering,
    /// so any other cursor is followed a page at a time, as GitHub hands them out.
    private static func remainingCursors(after first: SearchData.Search) -> [String]? {
        guard first.nodes.count == pageSize, first.pageInfo.endCursor == cursor(at: pageSize) else { return nil }
        let end = min(first.issueCount, searchResultCap)
        return stride(from: pageSize - 1, to: end - 1, by: pageSize - 1).map(cursor(at:))
    }

    /// Whether each page starts with the result the page before ended on. Search keeps results in one
    /// order, so then every result listed the whole time sits on one of the pages, however many arrived
    /// or left and whatever order GitHub answered in. Anything else, including an empty page, means
    /// results moved where a page starts.
    private static func areJoined(_ pages: [SearchData.Search]) -> Bool {
        zip(pages, pages.dropFirst()).allSatisfy { before, after in
            guard let last = before.nodes.last?.map(\.id), let first = after.nodes.first?.map(\.id) else { return false }
            return last == first
        }
    }

    static func cursor(at offset: Int) -> String {
        Data("cursor:\(offset)".utf8).base64EncodedString()
    }

    /// Fetches the pages that start at `cursors` a few at a time, rather than a round trip per page.
    private func searchPages(query terms: String, after cursors: [String]) async throws -> [SearchData.Search] {
        try await withThrowingTaskGroup(of: (Int, SearchData.Search).self) { group in
            var pages = [SearchData.Search?](repeating: nil, count: cursors.count)
            for (index, cursor) in cursors.enumerated() {
                if index >= Self.concurrentPages, let (done, page) = try await group.next() { pages[done] = page }
                group.addTask { (index, try await searchPage(query: terms, after: cursor)) }
            }
            for try await (done, page) in group { pages[done] = page }
            return pages.map { $0! }
        }
    }

    private func searchPage(query terms: String, after cursor: String?) async throws -> SearchData.Search {
        let query = """
        query($q: String!, $after: String) {
          search(type: ISSUE, query: $q, first: \(Self.pageSize), after: $after) {
            issueCount
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on PullRequest {
                id title url createdAt mergedAt state isDraft
                repository { nameWithOwner }
              }
            }
          }
        }
        """
        var variables = ["q": terms]
        variables["after"] = cursor
        let data: SearchData = try await send(query: query, variables: variables)
        return data.search
    }

    private func send<Response: Decodable>(query: String, variables: [String: String]) async throws -> Response {
        let body = try JSONEncoder().encode(Request(query: query, variables: variables))
        let data = try await deliver(body)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope<Response>
        do {
            envelope = try decoder.decode(Envelope<Response>.self, from: data)
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty {
            // Not JSON at all, so a page from whatever sits between this Mac and GitHub. Waiting won't fix it.
            throw GitHubError.notGitHub
        }
        // Partial data would silently undercount, so any GraphQL error fails the fetch.
        if let error = envelope.errors?.first { throw GitHubError.graphQL(error.message) }
        guard let result = envelope.data else { throw GitHubError.graphQL("Empty response") }
        return result
    }

    /// Retries the one request, so a blip on a late page doesn't cost the pages already fetched.
    private func deliver(_ body: Data) async throws -> Data {
        for delay in retryDelays {
            do {
                return try await transport(body)
            } catch where Self.isTransient(error) {
                try await Task.sleep(for: delay)
            }
        }
        return try await transport(body)
    }

    private static func isTransient(_ error: Error) -> Bool {
        switch error {
        case GitHubError.http(let status, _):
            [500, 502, 503, 504].contains(status)
        case let error as URLError:
            [
                .timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            ].contains(error.code)
        default:
            false
        }
    }

    /// What GitHub said about a failed request: REST's `message`, or the first GraphQL error.
    static func message(in body: Data) -> String? {
        guard let reply = try? JSONDecoder().decode(Refusal.self, from: body) else { return nil }
        let message = (reply.message ?? reply.errors?.first?.message)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return message?.isEmpty == false ? message : nil
    }

    /// UTC avoids a `+` offset in search queries and keeps month edges exact in any time zone.
    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

private struct Request: Encodable {
    let query: String
    let variables: [String: String]
}

private struct Envelope<Payload: Decodable>: Decodable {
    struct Failure: Decodable { let message: String }
    let data: Payload?
    let errors: [Failure]?
}

private struct Refusal: Decodable {
    struct Failure: Decodable { let message: String? }
    let message: String?
    let errors: [Failure]?
}

private struct ViewerData: Decodable {
    struct Viewer: Decodable {
        struct Contributions: Decodable {
            struct Calendar: Decodable { let totalContributions: Int }
            let contributionCalendar: Calendar
        }
        let login: String
        let contributionsCollection: Contributions
    }
    let viewer: Viewer
}

private struct SearchData: Decodable {
    struct Search: Decodable {
        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }
        let issueCount: Int
        let pageInfo: PageInfo
        let nodes: [PullRequest?]
    }
    let search: Search
}
