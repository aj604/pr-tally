import Foundation
import Testing
@testable import TallyCore

/// Answers with `status` and, when given, an `X-OAuth-Scopes` header, recording the request it was sent.
private final class FakeUser: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    let status: Int
    let scopes: String?

    init(status: Int = 200, scopes: String?) {
        self.status = status
        self.scopes = scopes
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func load(_ request: URLRequest) -> (Data, URLResponse) {
        lock.withLock { sent.append(request) }
        let headers = scopes.map { ["X-OAuth-Scopes": $0] } ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data("{\"login\":\"alice\"}".utf8), response)
    }
}

@Suite struct TokenScopesTests {
    @Test(arguments: ["repo", "repo, read:org", "gist, repo, workflow", "read:org,repo"])
    func theRepoScopeReadsPrivateRepos(scopes: String) {
        #expect(TokenScopes.readsPrivateRepos(scopes: scopes) == true)
    }

    /// The narrower scopes look like `repo` but leave private repos out of search.
    @Test(arguments: ["", "public_repo", "public_repo, read:user", "repo:status, repo_deployment", "read:org"])
    func scopesWithoutRepoDont(scopes: String) {
        #expect(TokenScopes.readsPrivateRepos(scopes: scopes) == false)
    }

    @Test func aTokenWithNoScopeListSaysNothing() {
        #expect(TokenScopes.readsPrivateRepos(scopes: nil) == nil)
    }

    @Test func asksGitHubWithTheToken() async {
        let github = FakeUser(scopes: "public_repo")
        #expect(await TokenScopes.readsPrivateRepos("ghp_test", load: { github.load($0) }) == false)
        let request = try! #require(github.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/user")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "bearer ghp_test")
    }

    /// A fine-grained token is answered without the header.
    @Test func aFineGrainedTokenSaysNothing() async {
        let github = FakeUser(scopes: nil)
        #expect(await TokenScopes.readsPrivateRepos("github_pat_test", load: { github.load($0) }) == nil)
    }

    /// A rejected token's scopes aren't its own to judge; the refresh reports the rejection.
    @Test func aRejectionOrNoAnswerSaysNothing() async {
        let rejected = FakeUser(status: 401, scopes: "")
        #expect(await TokenScopes.readsPrivateRepos("ghp_test", load: { rejected.load($0) }) == nil)
        #expect(await TokenScopes.readsPrivateRepos("ghp_test", load: { _ in throw URLError(.notConnectedToInternet) }) == nil)
    }
}
