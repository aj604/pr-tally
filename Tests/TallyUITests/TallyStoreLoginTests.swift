import Foundation
import Testing
import TallyCore
@testable import TallyUI

private final class LoginDefaults: UserDefaults, @unchecked Sendable {
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

private func snapshot(login: String, opened: Int) -> MonthSnapshot {
    let now = Date()
    let prs = (0..<opened).map {
        PullRequest(
            id: "\(login)-\($0)", title: "", url: URL(string: "https://github.com")!, createdAt: now, mergedAt: nil,
            repository: .init(nameWithOwner: "\(login)/app")
        )
    }
    return MonthSnapshot(
        login: login, window: MonthWindow(containing: now), opened: prs, merged: [], totalContributions: 0, fetchedAt: now
    )
}

/// Stands in for the keychain and `GitHubClient`: a fetch reads the login once as it starts and keeps it to the
/// end, as the real client pins its credentials for a whole refresh.
private actor Account {
    private var login: String
    private(set) var fetchedAs: [String] = []
    /// What each login's fetches return, in order, repeating the last.
    private var results: [String: [Result<MonthSnapshot, Error>]]
    /// Which fetch, counting from zero, is held open until the test lets it finish.
    private let holding: Int?
    private var held: CheckedContinuation<Void, Never>?

    init(_ login: String, holding: Int? = 0, results: [String: [Result<MonthSnapshot, Error>]]) {
        self.login = login
        self.holding = holding
        self.results = results
    }

    func fetch() async throws -> MonthSnapshot {
        let pinned = login
        fetchedAs.append(pinned)
        if fetchedAs.count - 1 == holding { await withCheckedContinuation { held = $0 } }
        let queue = results[pinned]!
        if queue.count > 1 { results[pinned]!.removeFirst() }
        return try queue[0].get()
    }

    func switchTo(_ login: String) { self.login = login }

    func release() {
        held?.resume()
        held = nil
    }

    var isHolding: Bool { held != nil }
}

/// Saving or clearing a token while a refresh is under way, as when it's done right after opening the popover.
@MainActor
@Suite struct TallyStoreLoginTests {
    private func store(_ account: Account) -> TallyStore {
        TallyStore(defaults: LoginDefaults()) { try await account.fetch() }
    }

    private func startRefresh(_ store: TallyStore, _ account: Account) async throws -> Task<Void, Never> {
        let inFlight = Task { await store.refresh() }
        while await !account.isHolding { try await Task.sleep(for: .milliseconds(5)) }
        return inFlight
    }

    /// Switches the login while the held fetch is under way, then lets it finish.
    private func switchLogin(_ store: TallyStore, _ account: Account, to login: String, during inFlight: Task<Void, Never>) async {
        await account.switchTo(login)
        await store.loginChanged()
        await account.release()
        await inFlight.value
    }

    @Test func aTokenSavedDuringARefreshIsUsedBeforeAnyNumbersShow() async throws {
        let account = Account("old", results: [
            "old": [.success(snapshot(login: "old", opened: 40))], "new": [.success(snapshot(login: "new", opened: 7))],
        ])
        let store = store(account)
        await switchLogin(store, account, to: "new", during: try await startRefresh(store, account))
        #expect(await account.fetchedAs == ["old", "new"])
        #expect(store.snapshot?.login == "new")
        #expect(store.count == 7)
    }

    /// The old token's failure, such as GitHub rejecting the token just replaced, says nothing about the new one.
    @Test func theOldLoginsFailureIsNotReportedForTheNewOne() async throws {
        let account = Account("old", results: [
            "old": [.failure(GitHubError.unauthorized(.saved))], "new": [.success(snapshot(login: "new", opened: 7))],
        ])
        let store = store(account)
        await switchLogin(store, account, to: "new", during: try await startRefresh(store, account))
        #expect(store.errorMessage == nil)
        #expect(store.count == 7)
        #expect(store.nextDelay() == .seconds(15 * 60))
    }

    /// A new token that fails too is on its first failure, retried a minute later rather than backed off for the old one's.
    @Test func aNewLoginThatAlsoFailsStartsItsOwnRetries() async throws {
        let account = Account("old", results: [
            "old": [.failure(GitHubError.unauthorized(.saved))], "new": [.failure(GitHubError.http(502))],
        ])
        let store = store(account)
        await switchLogin(store, account, to: "new", during: try await startRefresh(store, account))
        #expect(store.errorMessage == GitHubError.http(502).errorDescription)
        #expect(store.nextDelay() == .seconds(60))
    }

    @Test func theOldLoginsNumbersAreNotSavedForNextLaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "PRTallyTests/\(UUID().uuidString)/snapshot.json")
        let account = Account("old", results: [
            "old": [.success(snapshot(login: "old", opened: 40))], "new": [.failure(GitHubError.unauthorized(.saved))],
        ])
        let store = TallyStore(defaults: LoginDefaults(), cache: SnapshotCache(url: url)) { try await account.fetch() }
        await switchLogin(store, account, to: "new", during: try await startRefresh(store, account))
        #expect(store.snapshot == nil)
        #expect(SnapshotCache(url: url).load() == nil)
        #expect(store.errorMessage == GitHubError.unauthorized(.saved).errorDescription)
    }

    /// A goal crossed by the account just left isn't the new one's, and the notification would be all anyone saw of it.
    @Test func theOldLoginReachingTheGoalIsNotAnnounced() async throws {
        let sent = Sent()
        let account = Account("old", holding: 1, results: [
            "old": [.success(snapshot(login: "old", opened: 5)), .success(snapshot(login: "old", opened: 12))],
            "new": [.success(snapshot(login: "new", opened: 3))],
        ])
        let store = TallyStore(defaults: LoginDefaults(), notify: { sent.milestones.append($0) }) { try await account.fetch() }
        store.goal = 10
        await store.refresh()
        await switchLogin(store, account, to: "new", during: try await startRefresh(store, account))
        #expect(sent.milestones.isEmpty)
        #expect(store.snapshot?.login == "new")
    }

    @Test func aLoginChangeWithNothingInFlightFetchesOnce() async {
        let account = Account("new", holding: nil, results: ["new": [.success(snapshot(login: "new", opened: 7))]])
        let store = store(account)
        await store.loginChanged()
        #expect(await account.fetchedAs == ["new"])
        #expect(store.count == 7)
    }

    /// Saving a token is asking for numbers, like Refresh now, so a pause doesn't hold back the fetch it needs.
    @Test func aLoginChangeWhilePausedStillFetchesWithTheNewLogin() async throws {
        let account = Account("old", results: [
            "old": [.success(snapshot(login: "old", opened: 40))], "new": [.success(snapshot(login: "new", opened: 7))],
        ])
        let store = store(account)
        store.automaticRefreshPaused = true
        await switchLogin(store, account, to: "new", during: try await startRefresh(store, account))
        #expect(await account.fetchedAs == ["old", "new"])
        #expect(store.count == 7)
    }
}

@MainActor private final class Sent {
    var milestones: [Milestone] = []
}
