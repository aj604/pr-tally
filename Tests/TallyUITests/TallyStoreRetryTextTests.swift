import Foundation
import Testing
import TallyCore
@testable import TallyUI

private struct Down: Error {}

private final class TextDefaults: UserDefaults, @unchecked Sendable {
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

private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// The schedule runs for real with a fixed clock, so the time it reports is exact. It sleeps for the full retry
/// delay, a minute or a quarter hour, and each test pauses it before returning.
@MainActor
@Suite(.serialized) struct TallyStoreRetryTextTests {
    private func store(
        clock: @escaping () -> Date = { noon }, _ results: @escaping @Sendable (Int) throws -> MonthSnapshot
    ) -> TallyStore {
        let calls = Calls()
        let store = TallyStore(
            defaults: TextDefaults(), network: NetworkStatus { AsyncStream { $0.yield(true) } }
        ) { try results(calls.next()) }
        store.clock = clock
        return store
    }

    private func snapshot() -> MonthSnapshot {
        MonthSnapshot(
            login: "me", window: MonthWindow(containing: noon), opened: [], merged: [], totalContributions: 0,
            fetchedAt: noon.addingTimeInterval(-600)
        )
    }

    /// Until the schedule has gone to sleep, which is when it knows its next try.
    private func asleep(_ store: TallyStore) async throws {
        for _ in 0..<500 where store.nextTryAt == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.nextTryAt != nil)
    }

    @Test func aFailedRefreshSaysWhenTheNextTryIs() async throws {
        let store = store { _ in throw Down() }
        store.start(observingSystem: false)
        try await asleep(store)
        #expect(store.updatedText(at: noon) == "Next try \(time(noon.addingTimeInterval(60)))")
        store.automaticRefreshPaused = true
    }

    @Test func itFollowsTheBackoffAndSitsBesideWhenTheNumbersWereFetched() async throws {
        let ok = snapshot()
        let store = store { if $0 == 1 { return ok }; throw Down() }
        store.start(observingSystem: false)
        try await asleep(store)
        #expect(store.updatedText(at: noon) == "Updated \(time(ok.fetchedAt))", "nothing to retry while it's working")
        // A failure from the refresh button lands in the middle of the schedule's normal wait.
        await store.refresh()
        let next = noon.addingTimeInterval(15 * 60)
        #expect(store.updatedText(at: noon) == "Updated \(time(ok.fetchedAt)) · Next try \(time(next))")
        store.automaticRefreshPaused = true
    }

    @Test func aSuccessTakesItAway() async throws {
        let ok = snapshot()
        let store = store { if $0 == 2 { return ok }; throw Down() }
        store.start(observingSystem: false)
        try await asleep(store)
        #expect(store.retryText(at: noon) != nil)
        // What the refresh button does, succeeding while the schedule is still waiting out the failure.
        await store.refresh()
        #expect(store.retryText(at: noon) == nil)
        #expect(store.updatedText(at: noon) == "Updated \(time(ok.fetchedAt))")
        store.automaticRefreshPaused = true
    }

    @Test func aRateLimitLeavesItToItsOwnMessage() async throws {
        let until = noon.addingTimeInterval(37 * 60)
        let store = store { _ in throw GitHubError.rateLimited(until: until) }
        store.start(observingSystem: false)
        try await asleep(store)
        #expect(store.nextTryAt == until)
        #expect(store.errorMessage?.contains(time(until)) == true)
        #expect(store.updatedText(at: noon) == nil)
        store.automaticRefreshPaused = true
    }

    @Test func waitingForTheNetworkHasNoTime() async throws {
        let store = store { _ in throw Down() }
        await store.refresh()
        await store.networkChanged(isOnline: false)
        await store.refreshIfStale(now: noon.addingTimeInterval(3600))
        #expect(store.errorMessage == TallyStore.offlineMessage)
        #expect(store.retryText(at: noon) == nil)
    }

    @Test func aPausedStoreSaysPausedNotRetrying() async throws {
        let store = store { _ in throw Down() }
        store.start(observingSystem: false)
        try await asleep(store)
        store.automaticRefreshPaused = true
        #expect(store.nextTryAt == nil)
        #expect(store.updatedText(at: noon) == "Automatic refresh paused")
    }

    @Test func aTimePastIsNotShown() async throws {
        let store = store { _ in throw Down() }
        store.start(observingSystem: false)
        try await asleep(store)
        #expect(store.retryText(at: noon.addingTimeInterval(61)) == nil, "a retry that is under way isn't 'next'")
        store.automaticRefreshPaused = true
    }

    @Test func voiceOverHearsItWhenTheMenuBarHasFaded() async throws {
        let store = store(clock: Date.init) { _ in throw Down() }
        store.staleGrace = 0
        store.start(observingSystem: false)
        try await asleep(store)
        #expect(store.menuBarIsStale)
        let label = store.menuBarAccessibilityLabel
        #expect(label.hasPrefix("PR Tally, not updating. Next try "), Comment(rawValue: label))
        store.automaticRefreshPaused = true
    }
}
