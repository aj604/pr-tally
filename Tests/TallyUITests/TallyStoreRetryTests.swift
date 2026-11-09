import Foundation
import Testing
import TallyCore
@testable import TallyUI

private struct Down: Error {}

private final class RetryDefaults: UserDefaults, @unchecked Sendable {
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

private let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!
private let minute = Duration.seconds(60)
private let quarterHour = Duration.seconds(15 * 60)

private func delay(_ failures: Int, _ error: Error? = Down(), base: Duration = minute, interval: Duration = quarterHour) -> Duration {
    TallyStoreRetry.delay(afterFailures: failures, error: error, base: base, interval: interval, now: noon)
}

@Suite struct TallyStoreRetryPacingTests {
    @Test func firstRetryIsSoonAndEachFailureDoublesTheWait() {
        #expect(delay(1) == .seconds(60))
        #expect(delay(2) == .seconds(120))
        #expect(delay(3) == .seconds(240))
        #expect(delay(4) == .seconds(480))
    }

    @Test func backoffNeverWaitsLongerThanARefreshIntervalOrOverflows() {
        #expect(delay(5) == quarterHour)
        #expect(delay(100_000) == quarterHour)
        // A short interval is not stretched past what the user asked for, but never below the base retry.
        #expect(delay(3, interval: .seconds(30)) == minute)
    }

    @Test func aRateLimitWaitsForItsDeadlinePastTheBackoffCeiling() {
        let until = noon.addingTimeInterval(40 * 60)
        #expect(delay(1, GitHubError.rateLimited(until: until)) == .seconds(40 * 60))
        // The backoff for a fifth failure is shorter than the limit's remainder, so the limit wins.
        #expect(delay(5, GitHubError.rateLimited(until: until)) == .seconds(40 * 60))
    }

    @Test func aRateLimitThatIsAlmostOverStillWaitsTheBaseRetry() {
        #expect(delay(1, GitHubError.rateLimited(until: noon.addingTimeInterval(5))) == minute)
        #expect(delay(1, GitHubError.rateLimited(until: noon.addingTimeInterval(-30))) == minute)
    }
}

@MainActor
@Suite(.serialized) struct TallyStoreRetryScheduleTests {
    private func store(
        _ results: @escaping @Sendable (Int) throws -> MonthSnapshot
    ) -> TallyStore {
        let calls = Counter()
        let store = TallyStore(defaults: RetryDefaults()) { try results(calls.next()) }
        store.clock = { noon }
        return store
    }

    private func snapshot() -> MonthSnapshot {
        MonthSnapshot(
            login: "me", window: MonthWindow(containing: noon), opened: [], merged: [], totalContributions: 0,
            fetchedAt: noon
        )
    }

    @Test func consecutiveFailuresBackOffAndASuccessStartsOver() async {
        let ok = snapshot()
        let store = store { if $0 == 4 { return ok }; throw Down() }
        #expect(store.nextDelay() == .seconds(15 * 60))
        await store.refresh()
        #expect(store.nextDelay() == .seconds(60))
        await store.refresh()
        #expect(store.nextDelay() == .seconds(120))
        await store.refresh()
        #expect(store.nextDelay() == .seconds(240))
        await store.refresh()
        #expect(store.nextDelay() == .seconds(15 * 60), "the fourth try succeeds, so the normal interval returns")
        // The next failure after a success is a first one again.
        let failing = self.store { _ in throw Down() }
        await failing.refresh()
        #expect(failing.nextDelay() == .seconds(60))
    }

    @Test func aRateLimitSetsTheNextTryToWhenItLifts() async {
        let until = noon.addingTimeInterval(37 * 60)
        let store = store { _ in throw GitHubError.rateLimited(until: until) }
        await store.refresh()
        #expect(store.nextDelay() == .seconds(37 * 60))
    }

    @Test func waitingForTheNetworkAfterARateLimitIsNotPacedByTheOldLimit() async {
        let calls = Counter()
        let until = noon.addingTimeInterval(37 * 60)
        let store = TallyStore(defaults: RetryDefaults(), network: NetworkStatus { AsyncStream { $0.yield(false) } }) {
            _ = calls.next()
            throw GitHubError.rateLimited(until: until)
        }
        store.clock = { noon }
        await store.refresh()
        await store.networkChanged(isOnline: false)
        await store.refreshIfStale(now: noon.addingTimeInterval(3600))
        #expect(store.errorMessage == TallyStore.offlineMessage)
        #expect(store.nextDelay() == .seconds(60))
    }

    @Test func changingTheIntervalShortensTheBackoffCeiling() async {
        let store = store { _ in throw Down() }
        store.refreshMinutes = 2
        for _ in 0..<5 { await store.refresh() }
        #expect(store.nextDelay() == .seconds(120))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
