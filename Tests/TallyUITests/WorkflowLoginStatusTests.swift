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
}
