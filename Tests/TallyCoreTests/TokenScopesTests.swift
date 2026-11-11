import Foundation
import Testing
@testable import TallyCore

/// Answers with `status` and, when given, `X-OAuth-Scopes` and `X-GitHub-SSO` headers, recording the request it was sent.
private final class FakeSearch: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    let status: Int
    let scopes: String?
    let sso: String?

    init(status: Int = 200, scopes: String?, sso: String? = nil) {
        self.status = status
        self.scopes = scopes
        self.sso = sso
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func load(_ request: URLRequest) -> (Data, URLResponse) {
        lock.withLock { sent.append(request) }
        var headers: [String: String] = [:]
        headers["X-OAuth-Scopes"] = scopes
        headers["X-GitHub-SSO"] = sso
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data("{\"total_count\":1,\"items\":[]}".utf8), response)
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

    /// GitHub's documented form lists the organizations' IDs.
    @Test func partialResultsCountTheOrganizationsLeftOut() {
        #expect(TokenScopes.unauthorizedSSOOrganizations(sso: "partial-results; organizations=21955855,20582480") == 2)
        #expect(TokenScopes.unauthorizedSSOOrganizations(sso: "partial-results; organizations=21955855") == 1)
        #expect(TokenScopes.unauthorizedSSOOrganizations(sso: "Partial-Results;organizations=1, 2, 3") == 3)
        // Something was left out even when the list doesn't say whose.
        #expect(TokenScopes.unauthorizedSSOOrganizations(sso: "partial-results") == 1)
    }

    /// `required` comes with a refused request, not a search that was answered.
    @Test(arguments: [nil, "", "required; url=https://github.com/orgs/acme/sso?authorization_request=abc"])
    func otherSSOHeadersLeaveNothingOut(sso: String?) {
        #expect(TokenScopes.unauthorizedSSOOrganizations(sso: sso) == 0)
    }

    /// The same search a refresh makes, so the SSO header is about the PRs being counted.
    @Test func searchesForTheTokensOwnPRs() async throws {
        let github = FakeSearch(scopes: "repo", sso: "partial-results; organizations=21955855,20582480")
        #expect(await TokenScopes.reach("ghp_test", load: { github.load($0) })
            == TokenReach(readsPrivateRepos: true, unauthorizedSSOOrganizations: 2))
        let request = try #require(github.requests.first)
        let url = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(url.host == "api.github.com" && url.path == "/search/issues")
        #expect(url.queryItems?.first { $0.name == "q" }?.value == "is:pr author:@me")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "bearer ghp_test")
    }

    @Test func aClassicTokenWithoutRepoAndNoSSOOrgs() async {
        let github = FakeSearch(scopes: "public_repo")
        #expect(await TokenScopes.reach("ghp_test", load: { github.load($0) })
            == TokenReach(readsPrivateRepos: false, unauthorizedSSOOrganizations: 0))
    }

    /// A fine-grained token has no scopes. Even if GitHub sent the header empty, it isn't a classic token missing `repo`.
    @Test(arguments: [nil, ""])
    func aFineGrainedTokenHasNoScopeFinding(scopes: String?) async {
        let github = FakeSearch(scopes: scopes)
        #expect(await TokenScopes.reach("github_pat_test", load: { github.load($0) })?.readsPrivateRepos == nil)
    }

    /// A rejected token's scopes aren't its own to judge; the refresh reports the rejection. A rate-limited
    /// search has nothing to go by either.
    @Test func aRejectionOrNoAnswerSaysNothing() async {
        let rejected = FakeSearch(status: 401, scopes: "")
        #expect(await TokenScopes.reach("ghp_test", load: { rejected.load($0) }) == nil)
        let limited = FakeSearch(status: 403, scopes: "repo", sso: "partial-results; organizations=1")
        #expect(await TokenScopes.reach("ghp_test", load: { limited.load($0) }) == nil)
        #expect(await TokenScopes.reach("ghp_test", load: { _ in throw URLError(.notConnectedToInternet) }) == nil)
    }
}
