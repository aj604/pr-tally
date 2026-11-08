import Foundation
import Observation
import Testing
import TallyCore
@testable import TallyUI

private final class WorkflowRefreshPauseDefaults: UserDefaults, @unchecked Sendable {
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

private actor WorkflowRefreshPauseFetch {
    private(set) var calls = 0

    func next(stale: Bool = false) -> MonthSnapshot {
        calls += 1
        let now = Date()
        return MonthSnapshot(
            login: "timed-pause-fixture", window: MonthWindow(containing: now), opened: [], merged: [],
            totalContributions: 0, fetchedAt: stale ? now.addingTimeInterval(-120) : now
        )
    }
}

@MainActor @Suite struct WorkflowRefreshPauseTests {
    private func store(
        defaults: UserDefaults = WorkflowRefreshPauseDefaults(), fetch: WorkflowRefreshPauseFetch = WorkflowRefreshPauseFetch(),
        stale: Bool = false
    ) -> TallyStore {
        TallyStore(defaults: defaults, network: NetworkStatus { AsyncStream { $0.finish() } }) { await fetch.next(stale: stale) }
    }

    private func waitForFetch(_ fetch: WorkflowRefreshPauseFetch) async throws {
        for _ in 0..<100 where await fetch.calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func oneHourIsAnElapsedHourAndTomorrowIsTheNextLocalMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 22, minute: 30))!
        #expect(WorkflowRefreshPause.oneHour.title == "1 hour")
        #expect(WorkflowRefreshPause.untilTomorrow.title == "Until tomorrow")
        #expect(WorkflowRefreshPause.oneHour.deadline(from: now, calendar: calendar).timeIntervalSince(now) == 3600)
        let tomorrow = WorkflowRefreshPause.untilTomorrow.deadline(from: now, calendar: calendar)
        #expect(calendar.dateComponents([.day, .hour, .minute], from: tomorrow) == DateComponents(day: 8, hour: 0, minute: 0))
    }

    @Test(arguments: [(3, 8, 23), (11, 1, 25)])
    func tomorrowFollowsTheCalendarAcrossDaylightSavingChanges(month: Int, day: Int, hours: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
        let deadline = WorkflowRefreshPause.untilTomorrow.deadline(from: midnight, calendar: calendar)
        #expect(deadline.timeIntervalSince(midnight) == Double(hours * 3600))
        #expect(calendar.component(.hour, from: deadline) == 0)
    }

    @Test func timedPauseSurvivesRelaunchAndShowsItsResumeTime() {
        let defaults = WorkflowRefreshPauseDefaults()
        let first = store(defaults: defaults)
        let deadline = Date().addingTimeInterval(3600)
        first.pauseAutomaticRefresh(until: deadline)
        let relaunched = store(defaults: defaults)
        #expect(relaunched.automaticRefreshPaused)
        #expect(relaunched.automaticRefreshResumeAt == deadline)
        let time = deadline.formatted(date: .abbreviated, time: .shortened)
        #expect(relaunched.workflowRefreshPauseExplanation.contains("Resumes automatically \(time)"))
        #expect(relaunched.menuBarAccessibilityLabel.contains("Resumes automatically \(time)"))
        #expect(relaunched.workflowRefreshPauseExplanation.contains("Refresh now still works"))
        #expect(relaunched.updatedText() == "Automatic refresh paused")
    }

    @Test func anExpiredSavedPauseResumesOnLaunchAndFetchesMissingNumbers() async throws {
        let defaults = WorkflowRefreshPauseDefaults()
        defaults.set(true, forKey: "workflowAutomaticRefreshPaused")
        defaults.set(Date().addingTimeInterval(-60), forKey: "workflowAutomaticRefreshResumeAt")
        let fetch = WorkflowRefreshPauseFetch()
        let store = store(defaults: defaults, fetch: fetch)
        defer { store.automaticRefreshPaused = true }
        #expect(!store.automaticRefreshPaused)
        #expect(store.automaticRefreshResumeAt == nil)
        #expect(defaults.object(forKey: "workflowAutomaticRefreshResumeAt") == nil)
        store.start(observingSystem: false)
        try await waitForFetch(fetch)
        #expect(await fetch.calls == 1)
        #expect(store.snapshot?.login == "timed-pause-fixture")
        #expect(!self.store(defaults: defaults).automaticRefreshPaused)
    }

    @Test func aLiveDeadlineResumesWithoutAnExternalEvent() async throws {
        let fetch = WorkflowRefreshPauseFetch()
        let store = store(fetch: fetch)
        defer { store.automaticRefreshPaused = true }
        store.pauseAutomaticRefresh(until: Date().addingTimeInterval(0.1))
        store.start(observingSystem: false)
        #expect(await fetch.calls == 0)
        try await waitForFetch(fetch)
        #expect(await fetch.calls == 1)
        #expect(!store.automaticRefreshPaused)
        #expect(store.automaticRefreshResumeAt == nil)
        #expect(store.updatedText()?.contains("Paused") == false)
        #expect(!store.menuBarAccessibilityLabel.contains("automatic refresh paused"))
    }

    @Test(arguments: [false, true])
    func timedResumeFetchesStaleNumbersButKeepsAFreshManualUpdate(stale: Bool) async throws {
        let fetch = WorkflowRefreshPauseFetch()
        let store = store(fetch: fetch, stale: stale)
        defer { store.automaticRefreshPaused = true }
        store.pauseAutomaticRefresh(until: Date().addingTimeInterval(0.1))
        await store.refresh()
        store.start(observingSystem: false)
        #expect(await fetch.calls == 1)
        for _ in 0..<100 where store.automaticRefreshPaused { try await Task.sleep(for: .milliseconds(10)) }
        let expectedCalls = stale ? 2 : 1
        for _ in 0..<100 where await fetch.calls < expectedCalls { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.automaticRefreshPaused)
        #expect(await fetch.calls == expectedCalls)
    }

    @Test func aRelaunchedFuturePauseWaitsThenResumes() async throws {
        let defaults = WorkflowRefreshPauseDefaults()
        store(defaults: defaults).pauseAutomaticRefresh(until: Date().addingTimeInterval(0.15))
        let fetch = WorkflowRefreshPauseFetch()
        let relaunched = store(defaults: defaults, fetch: fetch)
        defer { relaunched.automaticRefreshPaused = true }
        relaunched.start(observingSystem: false)
        #expect(relaunched.automaticRefreshPaused)
        #expect(await fetch.calls == 0)
        try await waitForFetch(fetch)
        #expect(await fetch.calls == 1)
        #expect(!relaunched.automaticRefreshPaused)
    }

    @Test(arguments: ["wake", "opening", "calendar", "network"])
    func automaticEventsResumeAnOverduePause(event: String) async throws {
        let fetch = WorkflowRefreshPauseFetch()
        let store = store(fetch: fetch)
        defer { store.automaticRefreshPaused = true }
        let now = Date()
        store.pauseAutomaticRefresh(until: now.addingTimeInterval(3600))
        store.start(observingSystem: false)
        if event == "network" { await store.networkChanged(isOnline: false) }
        let afterDeadline = now.addingTimeInterval(7200)
        store.clock = { afterDeadline }
        switch event {
        case "wake":
            store.systemWoke()
        case "opening":
            await store.refreshIfStale(now: afterDeadline)
        case "calendar":
            await store.calendarDayChanged()
        default:
            await store.networkChanged(isOnline: true)
        }
        try await waitForFetch(fetch)
        #expect(!store.automaticRefreshPaused)
        #expect(store.automaticRefreshResumeAt == nil)
        #expect(await fetch.calls == 1)
    }

    @Test func manualRefreshKeepsTheDeadlineAndManualResumeCancelsIt() async throws {
        let defaults = WorkflowRefreshPauseDefaults()
        let fetch = WorkflowRefreshPauseFetch()
        let store = store(defaults: defaults, fetch: fetch)
        let deadline = Date().addingTimeInterval(3600)
        store.pauseAutomaticRefresh(until: deadline)
        await store.refresh()
        #expect(await fetch.calls == 1)
        #expect(store.automaticRefreshPaused)
        #expect(store.automaticRefreshResumeAt == deadline)
        store.automaticRefreshPaused = false
        #expect(store.automaticRefreshResumeAt == nil)
        #expect(defaults.object(forKey: "workflowAutomaticRefreshResumeAt") == nil)
        #expect(!self.store(defaults: defaults).automaticRefreshPaused)
        store.automaticRefreshPaused = true
        store.resumeAutomaticRefreshIfDue(at: deadline.addingTimeInterval(1))
        #expect(store.automaticRefreshPaused)
        #expect(!store.workflowRefreshPauseExplanation.contains("Resumes automatically"))
    }

    @Test func changingTheDeadlineCancelsTheEarlierTimerAndKeepsAutomaticFetchesPaused() async throws {
        let fetch = WorkflowRefreshPauseFetch()
        let store = store(fetch: fetch)
        defer { store.automaticRefreshPaused = true }
        store.pauseAutomaticRefresh(until: Date().addingTimeInterval(0.05))
        store.start(observingSystem: false)
        let later = Date().addingTimeInterval(3600)
        store.pauseAutomaticRefresh(until: later)
        await store.refreshIfStale()
        store.systemWoke()
        await store.calendarDayChanged()
        await store.networkChanged(isOnline: false)
        await store.networkChanged(isOnline: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fetch.calls == 0)
        #expect(store.automaticRefreshPaused)
        #expect(store.automaticRefreshResumeAt == later)
        store.automaticRefreshPaused = true
        #expect(store.automaticRefreshResumeAt == nil)
        store.resumeAutomaticRefreshIfDue(at: later.addingTimeInterval(1))
        #expect(store.automaticRefreshPaused)
    }

    @Test func invalidOrUnpausedSavedDeadlinesDoNotCreateATimedPause() {
        let defaults = WorkflowRefreshPauseDefaults()
        defaults.set(true, forKey: "workflowAutomaticRefreshPaused")
        defaults.set("invalid", forKey: "workflowAutomaticRefreshResumeAt")
        let indefinite = store(defaults: defaults)
        #expect(indefinite.automaticRefreshPaused)
        #expect(indefinite.automaticRefreshResumeAt == nil)
        #expect(defaults.object(forKey: "workflowAutomaticRefreshResumeAt") == nil)
        defaults.set(false, forKey: "workflowAutomaticRefreshPaused")
        defaults.set(Date().addingTimeInterval(3600), forKey: "workflowAutomaticRefreshResumeAt")
        let active = store(defaults: defaults)
        #expect(!active.automaticRefreshPaused)
        #expect(active.automaticRefreshResumeAt == nil)
    }

    @Test func anAlreadyPassedDeadlineResumesImmediatelyWithoutStartingAnIdleStore() async throws {
        let fetch = WorkflowRefreshPauseFetch()
        let store = store(fetch: fetch)
        store.pauseAutomaticRefresh(until: Date().addingTimeInterval(-1))
        try await Task.sleep(for: .milliseconds(40))
        #expect(!store.automaticRefreshPaused)
        #expect(store.automaticRefreshResumeAt == nil)
        #expect(await fetch.calls == 0)
    }

    @Test func changingATimedPauseRedrawsItsStatus() {
        let store = store()
        store.automaticRefreshPaused = true
        let redraw = WorkflowRefreshPauseRedraw()
        withObservationTracking {
            _ = store.workflowRefreshPauseExplanation
            _ = store.menuBarAccessibilityLabel
        } onChange: { redraw.fired = true }
        store.pauseAutomaticRefresh(until: Date().addingTimeInterval(3600))
        #expect(redraw.fired)
    }
}

private final class WorkflowRefreshPauseRedraw: @unchecked Sendable {
    var fired = false
}
