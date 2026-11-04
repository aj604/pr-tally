import Foundation

public enum GitHubError: Error, Equatable, LocalizedError {
    case noToken
    case unauthorized
    case http(Int)
    case graphQL(String)

    public var errorDescription: String? {
        switch self {
        case .noToken: "No GitHub login found. Run `gh auth login` or add a token in Settings."
        case .unauthorized: "GitHub rejected the token. Run `gh auth login` or update it in Settings."
        case .http(let code): "GitHub returned HTTP \(code)."
        case .graphQL(let message): "GitHub error: \(message)"
        }
    }
}

/// Sends a GraphQL request body and returns the response body.
public typealias GraphQLTransport = @Sendable (Data) async throws -> Data

public struct GitHubClient: Sendable {
    /// GitHub search returns at most this many results per query, however many match.
    static let searchResultCap = 1000

    private let transport: GraphQLTransport

    public init(transport: @escaping GraphQLTransport) {
        self.transport = transport
    }

    /// A client that posts to api.github.com, asking `tokens` for credentials on each request.
    public init(tokens: TokenProvider, session: URLSession = .shared) {
        self.init { body in
            guard let token = await tokens.token() else { throw GitHubError.noToken }
            var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("PRTally", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                await tokens.invalidate()
                throw GitHubError.unauthorized
            }
            guard status == 200 else { throw GitHubError.http(status) }
            return data
        }
    }

    public func fetchSnapshot(at now: Date = Date(), calendar: Calendar = .current) async throws -> MonthSnapshot {
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
        while page.pageInfo.hasNextPage, let cursor = page.pageInfo.endCursor {
            page = try await searchPage(query: terms, after: cursor)
            results += page.nodes.compactMap { $0 }
        }
        return results
    }

    private func searchPage(query terms: String, after cursor: String?) async throws -> SearchData.Search {
        let query = """
        query($q: String!, $after: String) {
          search(type: ISSUE, query: $q, first: 100, after: $after) {
            issueCount
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on PullRequest {
                id title url createdAt mergedAt
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
        let data = try await transport(body)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope<Response>.self, from: data)
        // Partial data would silently undercount, so any GraphQL error fails the fetch.
        if let error = envelope.errors?.first { throw GitHubError.graphQL(error.message) }
        guard let result = envelope.data else { throw GitHubError.graphQL("Empty response") }
        return result
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
