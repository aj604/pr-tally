import Foundation
import Observation
import Testing
import TallyCore
@testable import TallyUI

private final class WorkflowRefreshDefaults: UserDefaults, @unchecked Sendable {
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

private actor WorkflowRefreshScript {
    private(set) var calls = 0

    func next(fresh: Bool = false) -> MonthSnapshot {
        calls += 1
        let now = Date()
        return MonthSnapshot(
            login: "fixture", window: MonthWindow(containing: now), opened: [], merged: [],
            totalContributions: 0, fetchedAt: fresh ? now : now.addingTimeInterval(-120)
        )
    }
}

@MainActor @Suite struct WorkflowRefreshTests {
    @Test func pauseDefaultsOffAndBothChoicesSurviveRelaunch() {
        let defaults = WorkflowRefreshDefaults()
        defaults.set("invalid", forKey: "workflowAutomaticRefreshPaused")
        let store = TallyStore(defaults: defaults) { throw CancellationError() }
        #expect(!store.automaticRefreshPaused)
        store.automaticRefreshPaused = true
        #expect(TallyStore(defaults: defaults) { throw CancellationError() }.automaticRefreshPaused)
        store.automaticRefreshPaused = false
        #expect(!TallyStore(defaults: defaults) { throw CancellationError() }.automaticRefreshPaused)
    }

    @Test func manualRefreshWorksWhilePausedAndOffline() async {
        let script = WorkflowRefreshScript()
        let store = TallyStore(defaults: WorkflowRefreshDefaults()) { await script.next() }
        store.automaticRefreshPaused = true
        #expect(store.updatedText() == "Automatic refresh paused")
        #expect(store.menuBarAccessibilityLabel.contains("automatic refresh paused"))
        #expect(!store.menuBarAccessibilityLabel.contains("loading"))
        await store.networkChanged(isOnline: false)
        await store.refresh()
        #expect(await script.calls == 1)
        #expect(store.snapshot?.login == "fixture")
        #expect(store.errorMessage == nil)
        #expect(store.automaticRefreshPaused)
        #expect(store.updatedText()?.hasSuffix(" · Paused") == true)
        #expect(store.menuBarAccessibilityLabel.contains("0 of 1,000 PRs opened"))
        #expect(store.menuBarAccessibilityLabel.contains("Last updated"))
        #expect(store.menuBarTitle() == "0")
    }

    @Test func pausedLaunchWakeAndIntervalChangesWaitUntilResume() async throws {
        let defaults = WorkflowRefreshDefaults()
        defaults.set(true, forKey: "workflowAutomaticRefreshPaused")
        let script = WorkflowRefreshScript()
        let store = TallyStore(defaults: defaults, network: NetworkStatus { AsyncStream { $0.yield(true) } }) {
            await script.next()
        }
        defer { store.automaticRefreshPaused = true }
        store.start(observingSystem: false)
        store.start(observingSystem: false)
        store.systemWoke()
        store.refreshMinutes = 5
        try await Task.sleep(for: .milliseconds(80))
        #expect(await script.calls == 0)
        store.automaticRefreshPaused = false
        for _ in 0..<100 where await script.calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await script.calls == 1)
        #expect(store.snapshot?.login == "fixture")
        #expect(store.refreshMinutes == 5)
        #expect(store.updatedText()?.contains("Paused") == false)
    }

    @Test func pausingCancelsScheduledRetriesAndResumingRetriesStaleData() async throws {
        let counter = WorkflowRefreshScript()
        let store = TallyStore(defaults: WorkflowRefreshDefaults(), network: NetworkStatus { AsyncStream { $0.yield(true) } }) {
            _ = await counter.next()
            throw CancellationError()
        }
        store.retryDelay = .milliseconds(20)
        defer { store.automaticRefreshPaused = true }
        store.start(observingSystem: false)
        for _ in 0..<100 where await counter.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await counter.calls > 0)
        store.automaticRefreshPaused = true
        let pausedCalls = await counter.calls
        try await Task.sleep(for: .milliseconds(80))
        #expect(await counter.calls == pausedCalls)
        store.systemWoke()
        store.refreshMinutes = 30
        try await Task.sleep(for: .milliseconds(40))
        #expect(await counter.calls == pausedCalls)
        store.automaticRefreshPaused = false
        for _ in 0..<100 where await counter.calls == pausedCalls { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await counter.calls > pausedCalls)
    }

    @Test func resumeKeepsJustFetchedNumbersAndAnUnstartedStoreIdle() async throws {
        let script = WorkflowRefreshScript()
        let store = TallyStore(defaults: WorkflowRefreshDefaults(), network: NetworkStatus { AsyncStream { $0.yield(true) } }) {
            await script.next(fresh: true)
        }
        store.automaticRefreshPaused = true
        store.automaticRefreshPaused = false
        try await Task.sleep(for: .milliseconds(40))
        #expect(await script.calls == 0)
        store.start(observingSystem: false)
        for _ in 0..<100 where await script.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        store.automaticRefreshPaused = true
        store.automaticRefreshPaused = false
        try await Task.sleep(for: .milliseconds(80))
        #expect(await script.calls == 1)
        store.automaticRefreshPaused = true
    }

    @Test func pausingLetsInFlightWorkFinishWithoutCalendarFollowUp() async throws {
        let gate = WorkflowRefreshGate()
        let script = WorkflowRefreshScript()
        let store = TallyStore(defaults: WorkflowRefreshDefaults()) {
            await gate.wait()
            return await script.next()
        }
        let refresh = Task { await store.refreshIfStale() }
        for _ in 0..<100 where !(await gate.started) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.started)
        store.automaticRefreshPaused = true
        await store.calendarDayChanged()
        await gate.release()
        await refresh.value
        #expect(await script.calls == 1)
        #expect(store.snapshot?.login == "fixture")
        #expect(!store.isRefreshing)
    }

    @Test func pausingSuppressesAnInFlightFailureNetworkFollowUp() async throws {
        let gate = WorkflowRefreshGate()
        let script = WorkflowRefreshScript()
        let store = TallyStore(defaults: WorkflowRefreshDefaults()) {
            await gate.wait()
            _ = await script.next()
            throw CancellationError()
        }
        let refresh = Task { await store.refreshIfStale() }
        for _ in 0..<100 where !(await gate.started) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.started)
        await store.networkChanged(isOnline: false)
        await store.networkChanged(isOnline: true)
        store.automaticRefreshPaused = true
        await gate.release()
        await refresh.value
        #expect(await script.calls == 1)
        #expect(store.errorMessage != nil)
        #expect(!store.isRefreshing)
    }

    @Test func networkRecoveryKeepsAFailedRefreshPausedUntilResume() async throws {
        let script = WorkflowRefreshScript()
        let store = TallyStore(defaults: WorkflowRefreshDefaults()) {
            _ = await script.next()
            throw CancellationError()
        }
        store.automaticRefreshPaused = true
        await store.refresh()
        await store.networkChanged(isOnline: false)
        await store.networkChanged(isOnline: true)
        #expect(await script.calls == 1)
        #expect(store.errorMessage != nil)
        store.automaticRefreshPaused = false
        await store.networkChanged(isOnline: false)
        await store.networkChanged(isOnline: true)
        #expect(await script.calls == 2)
    }

    @Test func pausedStatusRedrawsAndRestoresTheUsualLabelsWhenResumed() {
        let store = TallyStore(defaults: WorkflowRefreshDefaults()) { throw CancellationError() }
        let redraw = WorkflowRefreshRedraw()
        withObservationTracking {
            _ = store.updatedText()
            _ = store.menuBarAccessibilityLabel
        } onChange: { redraw.fired = true }
        store.automaticRefreshPaused = true
        #expect(redraw.fired)
        #expect(store.menuBarAccessibilityLabel.hasPrefix("PR Tally, automatic refresh paused."))
        store.automaticRefreshPaused = false
        #expect(store.menuBarAccessibilityLabel == "PR Tally, loading")
        #expect(store.updatedText() == nil)
    }

    @Test func savedPauseStopsOpeningCalendarAndNetworkRefreshes() async {
        let defaults = WorkflowRefreshDefaults()
        defaults.set(true, forKey: "workflowAutomaticRefreshPaused")
        let script = WorkflowRefreshScript()
        let store = TallyStore(defaults: defaults) { await script.next() }
        await store.refreshIfStale()
        await store.calendarDayChanged()
        await store.networkChanged(isOnline: false)
        await store.refreshIfStale()
        await store.networkChanged(isOnline: true)
        print("Saved pause: automatic fetches = \(await script.calls)")
        #expect(await script.calls == 0)
        #expect(store.snapshot == nil)
        #expect(store.errorMessage == nil)
    }
}

private actor WorkflowRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private var open = false

    func wait() async {
        started = true
        if !open { await withCheckedContinuation { continuation = $0 } }
    }

    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}

private final class WorkflowRefreshRedraw: @unchecked Sendable {
    var fired = false
}
