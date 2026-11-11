import Foundation
import Testing
import TallyCore
@testable import TallyUI

private final class LoginStatusDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func set(_ value: Int, forKey key: String) { set(value as Any?, forKey: key) }
    override func set(_ value: Bool, forKey key: String) { set(value as Any?, forKey: key) }
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
}

private func snapshot(login: String) -> MonthSnapshot {
    let now = Date()
    return MonthSnapshot(
        login: login, window: MonthWindow(containing: now), opened: [], merged: [], totalContributions: 0, fetchedAt: now
    )
}

/// Answers each fetch with the next queued result, repeating the last, and can hold one open until released.
private actor Replies {
    private var queue: [Result<MonthSnapshot, Error>]
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?

    init(_ queue: [Result<MonthSnapshot, Error>]) { self.queue = queue }

    func fetch() async throws -> MonthSnapshot {
        if holdNext {
            holdNext = false
            await withCheckedContinuation { held = $0 }
        }
        let next = queue[0]
        if queue.count > 1 { queue.removeFirst() }
        return try next.get()
    }

    func holdTheNextFetch() { holdNext = true }

    func release() {
        held?.resume()
        held = nil
    }

    var isHolding: Bool { held != nil }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@MainActor @Suite struct WorkflowLoginStatusTests {
    private func store(_ replies: Replies) -> TallyStore {
        TallyStore(defaults: LoginStatusDefaults()) { try await replies.fetch() }
    }

    private func state(_ store: TallyStore) -> WorkflowLoginStatus.State {
        store.workflowLoginStatus(usesSavedToken: false).state
    }

    @Test func noNumbersYetSaysOnlyWhichLoginIsUsed() {
        let store = store(Replies([.success(snapshot(login: "alice"))]))
        #expect(state(store) == .unknown)
        #expect(store.workflowLoginStatus(usesSavedToken: true).text == "Using the token saved in your keychain.")
    }

    @Test func aGoodRefreshNamesTheAccountItCounted() async {
        let store = store(Replies([.success(snapshot(login: "alice"))]))
        await store.refresh()
        #expect(state(store) == .counting(login: "alice"))
        #expect(store.workflowLoginStatus(usesSavedToken: true).text
            == "Counting PRs for @alice with the token saved in your keychain.")
    }

    /// The case this replaces "Using your gh login" for: there is no gh login to use.
    @Test(arguments: [GitHubError.noGitHubCLI, .noToken, .unauthorized(.githubCLI), .unauthorized(.saved)])
    func aLoginThatCantBeUsedIsAWarningRatherThanUsing(error: GitHubError) async {
        let store = store(Replies([.failure(error)]))
        await store.refresh()
        let status = store.workflowLoginStatus(usesSavedToken: error == .unauthorized(.saved))
        #expect(status.state == .unusable(error))
        #expect(status.isWarning)
        #expect(!status.text.hasPrefix("Using"))
    }

    /// GitHub being down or the token being rate limited says nothing about whose numbers these are.
    @Test(arguments: [GitHubError.http(502), .rateLimited(until: .distantFuture), .notGitHub])
    func otherFailuresKeepNamingTheCountedAccount(error: GitHubError) async {
        let store = store(Replies([.success(snapshot(login: "alice")), .failure(error)]))
        await store.refresh()
        await store.refresh()
        #expect(store.errorMessage != nil)
        #expect(state(store) == .counting(login: "alice"))
    }

    @Test func aRejectedTokenIsReportedEvenWithAnEarlierAccountsNumbersOnScreen() async {
        let store = store(Replies([.success(snapshot(login: "alice")), .failure(GitHubError.unauthorized(.saved))]))
        await store.refresh()
        await store.loginChanged()
        #expect(store.snapshot?.login == "alice")
        #expect(store.workflowLoginStatus(usesSavedToken: true).state == .unusable(.unauthorized(.saved)))
    }

    /// The numbers on screen are still the replaced login's, so naming their account would say the new token works.
    @Test func aNewLoginThatHasntReachedGitHubIsNotCreditedWithTheOldAccount() async {
        let store = store(Replies([.success(snapshot(login: "alice")), .failure(GitHubError.http(502))]))
        await store.refresh()
        await store.loginChanged()
        #expect(store.snapshot?.login == "alice")
        #expect(state(store) == .unconfirmed)
        #expect(!store.workflowLoginStatus(usesSavedToken: true).text.contains("@alice"))
    }

    /// While the new token is being tried, the rejection on record is the old one's and isn't shown against it.
    @Test func aSavedTokenIsCheckingUntilItsRefreshEnds() async throws {
        let replies = Replies([.failure(GitHubError.unauthorized(.githubCLI)), .success(snapshot(login: "bob"))])
        let store = store(replies)
        await store.refresh()
        #expect(state(store) == .unusable(.unauthorized(.githubCLI)))
        await replies.holdTheNextFetch()
        let saving = Task { await store.loginChanged() }
        while await !replies.isHolding { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.workflowLoginStatus(usesSavedToken: true).state == .checking)
        #expect(store.workflowLoginStatus(usesSavedToken: true).text == "Checking the new token with GitHub…")
        await replies.release()
        await saving.value
        #expect(store.workflowLoginStatus(usesSavedToken: true).state == .counting(login: "bob"))
    }

    @Test func aLaterGoodRefreshConfirmsALoginThatWasWaiting() async {
        let store = store(Replies([
            .success(snapshot(login: "alice")), .failure(GitHubError.http(502)), .success(snapshot(login: "bob")),
        ]))
        await store.refresh()
        await store.loginChanged()
        #expect(state(store) == .unconfirmed)
        await store.refresh()
        #expect(state(store) == .counting(login: "bob"))
    }

    /// Saving a new token replaces the old one's rejection, whether or not the new one can be checked yet.
    @Test func aNewLoginIsNotWarnedAboutForTheOldOnesRejection() async {
        let store = store(Replies([.failure(GitHubError.unauthorized(.githubCLI)), .failure(GitHubError.http(502))]))
        await store.refresh()
        await store.loginChanged()
        #expect(state(store) == .unconfirmed)
    }

    /// Waiting for the network forgets the last failure for retries, but the login GitHub turned down is no better.
    @Test func goingOfflineKeepsARejectionShown() async {
        let store = store(Replies([.success(snapshot(login: "alice")), .failure(GitHubError.unauthorized(.saved))]))
        await store.refresh()
        await store.refresh()
        await store.networkChanged(isOnline: false)
        await store.refreshIfStale(now: Date().addingTimeInterval(10 * 60))
        #expect(store.errorMessage == TallyStore.offlineMessage)
        #expect(store.workflowLoginStatus(usesSavedToken: true).state == .unusable(.unauthorized(.saved)))
    }

    /// A relaunch shows the saved numbers, which are still the replaced login's until one of its refreshes succeeds.
    @Test func anUncheckedLoginStaysUncheckedAfterRelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "PRTallyTests/\(UUID().uuidString)/snapshot.json")
        let defaults = LoginStatusDefaults()
        let first = TallyStore(defaults: defaults, cache: SnapshotCache(url: url)) {
            throw GitHubError.http(502)
        }
        let before = TallyStore(defaults: defaults, cache: SnapshotCache(url: url)) { snapshot(login: "alice") }
        await before.refresh()
        await first.loginChanged()
        #expect(state(first) == .unconfirmed)

        let replies = Replies([.failure(GitHubError.http(502)), .success(snapshot(login: "bob"))])
        let relaunched = TallyStore(defaults: defaults, cache: SnapshotCache(url: url)) { try await replies.fetch() }
        #expect(relaunched.snapshot?.login == "alice")
        #expect(state(relaunched) == .unconfirmed)
        await replies.holdTheNextFetch()
        let launchRefresh = Task { await relaunched.refresh() }
        while await !replies.isHolding { try await Task.sleep(for: .milliseconds(5)) }
        #expect(state(relaunched) == .checking)
        await replies.release()
        await launchRefresh.value
        #expect(state(relaunched) == .unconfirmed)
        await relaunched.refresh()
        #expect(state(relaunched) == .counting(login: "bob"))

        let again = TallyStore(defaults: defaults, cache: SnapshotCache(url: url)) { throw CancellationError() }
        #expect(state(again) == .counting(login: "bob"))
    }

    /// A launch that starts offline would otherwise name the account these numbers were counted for as working.
    @Test(arguments: [GitHubError.noGitHubCLI, .noToken, .unauthorized(.githubCLI), .unauthorized(.saved)])
    func aRejectionIsStillShownAfterRelaunch(error: GitHubError) async {
        let defaults = LoginStatusDefaults()
        let first = TallyStore(defaults: defaults) { throw error }
        await first.refresh()
        let relaunched = TallyStore(defaults: defaults) { snapshot(login: "alice") }
        #expect(state(relaunched) == .unusable(error))
        await relaunched.refresh()
        #expect(state(relaunched) == .counting(login: "alice"))
        // No numbers are saved without a cache, so all a cleared rejection leaves is which login is used.
        #expect(state(TallyStore(defaults: defaults) { throw CancellationError() }) == .unknown)
    }

    @Test func theGhLoginKeepsTheAdviceForUsingAnotherAccount() {
        let status = WorkflowLoginStatus(usesSavedToken: false, state: .counting(login: "alice"))
        #expect(status.text == "Counting PRs for @alice with your gh login. \(WorkflowLoginStatus.tokenAdvice)")
        #expect(!status.isWarning)
        #expect(!WorkflowLoginStatus(usesSavedToken: true, state: .counting(login: "alice")).text.contains("different account"))
    }

    @Test func eachUnusableLoginSaysHowToFixIt() {
        func text(_ error: GitHubError) -> String { WorkflowLoginStatus(usesSavedToken: false, state: .unusable(error)).text }
        #expect(text(.noGitHubCLI).contains("isn't installed"))
        #expect(text(.noToken).contains("Run `gh auth login`"))
        #expect(text(.unauthorized(.githubCLI)).contains("rejected your gh login"))
        #expect(text(.unauthorized(.saved)).contains("clear it to use your gh login"))
    }

    private func store(_ replies: Replies, readsPrivateRepos: Bool?) -> TallyStore {
        let store = store(replies)
        store.tokenReach = { _ in readsPrivateRepos.map { TokenReach(readsPrivateRepos: $0) } }
        return store
    }

    /// The refresh succeeds and names the account, so this is the only sign its count leaves out private repos.
    @Test func aSavedTokenWithoutRepoScopeIsAWarningThoughItsRefreshesWork() async {
        let store = store(Replies([.success(snapshot(login: "alice"))]), readsPrivateRepos: false)
        await store.refresh()
        await store.checkSavedToken("ghp_public")
        let status = store.workflowLoginStatus(usesSavedToken: true)
        #expect(status.state == .counting(login: "alice"))
        #expect(status.isWarning)
        #expect(status.text.hasPrefix("Counting only PRs in public repos for @alice: "))
        #expect(status.text.contains("doesn't have the `repo` scope"))
        // Clearing the token goes back to gh, whose scopes this said nothing about.
        #expect(!store.workflowLoginStatus(usesSavedToken: false).isWarning)
    }

    @Test func aSavedTokenWithRepoScopeIsCountedAsBefore() async {
        let store = store(Replies([.success(snapshot(login: "alice"))]), readsPrivateRepos: true)
        await store.refresh()
        await store.checkSavedToken("ghp_private")
        let status = store.workflowLoginStatus(usesSavedToken: true)
        #expect(!status.isWarning)
        #expect(status.text == "Counting PRs for @alice with the token saved in your keychain.")
    }

    @Test func aMissingScopeIsSaidBeforeAnyNumbersArrive() async {
        let store = store(Replies([.failure(GitHubError.http(502))]), readsPrivateRepos: false)
        await store.checkSavedToken("ghp_public")
        #expect(store.workflowLoginStatus(usesSavedToken: true).text.hasPrefix(
            "The token saved in your keychain doesn't have the `repo` scope, so PRs in private repos won't be counted."))
    }

    /// A rejection is what to fix first, and a token just saved is the old one's finding until checked again.
    @Test func aRejectionOrANewTokenReplacesTheScopeWarning() async {
        let store = store(Replies([.failure(GitHubError.unauthorized(.saved)), .success(snapshot(login: "bob"))]),
            readsPrivateRepos: false)
        await store.checkSavedToken("ghp_public")
        await store.refresh()
        #expect(store.workflowLoginStatus(usesSavedToken: true).state == .unusable(.unauthorized(.saved)))
        #expect(store.workflowLoginStatus(usesSavedToken: true).text.hasPrefix("GitHub rejected"))
        await store.loginChanged()
        #expect(!store.workflowLoginStatus(usesSavedToken: true).isWarning)
    }

    /// Settings checks again on each opening; offline, the last answer stands rather than reading as fixed.
    @Test func noAnswerKeepsTheLastFinding() async {
        let store = store(Replies([.success(snapshot(login: "alice"))]), readsPrivateRepos: false)
        await store.checkSavedToken("ghp_public")
        store.tokenReach = { _ in nil }
        await store.checkSavedToken("ghp_public")
        #expect(store.savedTokenSkipsPrivateRepos)
    }

    /// A request with a rate-limited token can extend the limit, so the check waits it out like refreshes do.
    @Test func aRateLimitedTokenIsNotAsked() async {
        let limited = GitHubError.rateLimited(until: Date().addingTimeInterval(30 * 60))
        let store = store(Replies([.success(snapshot(login: "alice")), .failure(limited)]), readsPrivateRepos: false)
        await store.checkSavedToken("ghp_public")
        await store.refresh()
        await store.refresh()
        let asked = Counter()
        store.tokenReach = { _ in
            await asked.increment()
            return TokenReach(readsPrivateRepos: true)
        }
        await store.checkSavedToken("ghp_public")
        #expect(await asked.value == 0)
        #expect(store.savedTokenSkipsPrivateRepos)
    }

    /// The old token's limit is no reason to skip a new one, which its refresh shows once it's back.
    @Test func aNewTokensCheckWaitsForItsRefreshRatherThanTheOldLimit() async throws {
        let limited = GitHubError.rateLimited(until: Date().addingTimeInterval(30 * 60))
        let replies = Replies([.failure(limited), .success(snapshot(login: "bob"))])
        let store = store(replies, readsPrivateRepos: false)
        await store.refresh()
        await replies.holdTheNextFetch()
        let saving = Task { await store.loginChanged() }
        while await !replies.isHolding { try await Task.sleep(for: .milliseconds(5)) }
        let checking = Task { await store.checkSavedToken("ghp_new") }
        await replies.release()
        await saving.value
        await checking.value
        #expect(store.savedTokenSkipsPrivateRepos)
    }

    /// The old token's answer, arriving after a new one was saved, says nothing about the new one.
    @Test func aCheckOfAReplacedTokenIsDropped() async throws {
        let store = store(Replies([.success(snapshot(login: "bob"))]))
        let gate = AsyncStream<Void>.makeStream()
        let asked = AsyncStream<Void>.makeStream()
        store.tokenReach = { _ in
            asked.continuation.yield()
            for await _ in gate.stream { break }
            return TokenReach(readsPrivateRepos: false, unauthorizedSSOOrganizations: 2)
        }
        let checking = Task { await store.checkSavedToken("ghp_old") }
        for await _ in asked.stream { break }
        await store.loginChanged()
        gate.continuation.yield()
        await checking.value
        #expect(!store.savedTokenSkipsPrivateRepos)
        #expect(store.savedTokenUnauthorizedSSOOrganizations == 0)
    }

    private func store(_ replies: Replies, reach: TokenReach?) -> TallyStore {
        let store = store(replies)
        store.tokenReach = { _ in reach }
        return store
    }

    /// A token with `repo` that isn't authorized for an SSO org searches fine too, and GitHub leaves that org out.
    @Test func aSavedTokenNotAuthorizedForSSOOrgsIsAWarning() async {
        let store = store(Replies([.success(snapshot(login: "alice"))]),
            reach: TokenReach(readsPrivateRepos: true, unauthorizedSSOOrganizations: 2))
        await store.refresh()
        await store.checkSavedToken("ghp_sso")
        let status = store.workflowLoginStatus(usesSavedToken: true)
        #expect(status.state == .counting(login: "alice"))
        #expect(status.isWarning)
        #expect(status.text == "Counting PRs for @alice, but not in 2 organizations that use SSO: the token saved in "
            + "your keychain isn't authorized for them, so GitHub's search leaves their PRs out. \(WorkflowLoginStatus.ssoFix)")
        // The gh login is a different token, which this said nothing about.
        #expect(!store.workflowLoginStatus(usesSavedToken: false).isWarning)
    }

    @Test func oneSSOOrgAndNoNumbersYet() {
        let status = WorkflowLoginStatus(usesSavedToken: true, state: .unconfirmed, unauthorizedSSOOrganizations: 1)
        #expect(status.isWarning)
        #expect(status.text.hasPrefix("GitHub's search leaves out PRs in 1 organization that uses SSO: the token saved "
            + "in your keychain isn't authorized for it."))
    }

    @Test func aMissingScopeAndSSOOrgsAreBothSaid() {
        let status = WorkflowLoginStatus(
            usesSavedToken: true, state: .counting(login: "alice"), skipsPrivateRepos: true, unauthorizedSSOOrganizations: 3)
        #expect(status.text.hasPrefix("Counting only PRs in public repos for @alice: "))
        #expect(status.text.hasSuffix("It also isn't authorized for 3 organizations that use SSO, whose PRs are left out too."))
    }

    /// A rejection is what to fix first, and while a new token is checked the finding is the old one's.
    @Test func aRejectionOrACheckingTokenHidesTheSSOWarning() {
        for state in [WorkflowLoginStatus.State.unusable(.unauthorized(.saved)), .checking] {
            let status = WorkflowLoginStatus(usesSavedToken: true, state: state, unauthorizedSSOOrganizations: 2)
            #expect(!status.text.contains("SSO:"))
            #expect(status.isWarning == (state != .checking))
        }
    }

    /// Authorizing the org on GitHub clears it on the next check; offline, the last finding stands.
    @Test func theSSOFindingFollowsTheLatestAnswer() async {
        let store = store(Replies([.success(snapshot(login: "alice"))]),
            reach: TokenReach(readsPrivateRepos: true, unauthorizedSSOOrganizations: 1))
        await store.checkSavedToken("ghp_sso")
        store.tokenReach = { _ in nil }
        await store.checkSavedToken("ghp_sso")
        #expect(store.savedTokenUnauthorizedSSOOrganizations == 1)
        store.tokenReach = { _ in TokenReach(readsPrivateRepos: true) }
        await store.checkSavedToken("ghp_sso")
        #expect(store.savedTokenUnauthorizedSSOOrganizations == 0)
        #expect(!store.workflowLoginStatus(usesSavedToken: true).isWarning)
    }

    /// A fine-grained token has no scopes to report, which mustn't clear or set the scope finding.
    @Test func noScopeAnswerKeepsTheScopeFindingButTakesTheSSOOne() async {
        let store = store(Replies([.success(snapshot(login: "alice"))]), readsPrivateRepos: false)
        await store.checkSavedToken("ghp_public")
        store.tokenReach = { _ in TokenReach(readsPrivateRepos: nil, unauthorizedSSOOrganizations: 1) }
        await store.checkSavedToken("ghp_public")
        #expect(store.savedTokenSkipsPrivateRepos)
        #expect(store.savedTokenUnauthorizedSSOOrganizations == 1)
    }

    @Test func savingANewTokenClearsTheSSOFinding() async {
        let store = store(Replies([.success(snapshot(login: "alice"))]),
            reach: TokenReach(readsPrivateRepos: true, unauthorizedSSOOrganizations: 2))
        await store.checkSavedToken("ghp_sso")
        await store.loginChanged()
        #expect(store.savedTokenUnauthorizedSSOOrganizations == 0)
    }
}
