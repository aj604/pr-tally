import Foundation
import Observation
import Testing
import TallyCore
@testable import TallyUI

private final class WorkflowMenuBarDefaults: UserDefaults, @unchecked Sendable {
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

@MainActor @Suite struct WorkflowMenuBarTests {
    private func date(month: Int = 11, day: Int = 16) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    private func snapshot(at now: Date, before: Int = 40, today: Int = 2, fetchedAt: Date? = nil) -> MonthSnapshot {
        let window = MonthWindow(containing: now)
        let earlier = window.calendar.date(byAdding: .day, value: -1, to: now)!
        func prs(_ count: Int, at date: Date) -> [PullRequest] {
            (0..<count).map {
                PullRequest(
                    id: "\(date)-\($0)", title: "Fixture", url: URL(string: "https://github.com/me/app/pull/1")!,
                    createdAt: date, mergedAt: date, repository: .init(nameWithOwner: "me/app")
                )
            }
        }
        return MonthSnapshot(
            login: "fixture", window: window, opened: prs(before, at: earlier) + prs(today, at: now),
            merged: prs(9, at: earlier) + prs(1, at: now), totalContributions: 0, fetchedAt: fetchedAt ?? now
        )
    }

    @Test func monthProgressCanBeShownBesideTheRing() async {
        let now = date()
        let snapshot = snapshot(at: now)
        let defaults = WorkflowMenuBarDefaults()
        defaults.set("monthProgress", forKey: "workflowMenuBarDisplay")
        let store = TallyStore(defaults: defaults) { snapshot }
        await store.refresh()
        store.goal = 100
        print("Menu bar title: \(store.menuBarTitle(at: now)); month: \(store.count ?? -1); goal: \(store.goal)")
        #expect(store.menuBarTitle(at: now) == "42/100")
    }

    @Test(arguments: [nil, "unknown", "today"] as [String?])
    func absentOrUnknownSettingsKeepTodaysCount(saved: String?) async {
        let defaults = WorkflowMenuBarDefaults()
        defaults.set(saved, forKey: "workflowMenuBarDisplay")
        let now = date()
        let snapshot = snapshot(at: now)
        let store = TallyStore(defaults: defaults) { snapshot }
        await store.refresh()
        #expect(store.menuBarDisplay == .today)
        #expect(store.menuBarTitle(at: now) == "2")
    }

    @Test(arguments: WorkflowMenuBarDisplay.allCases)
    func eachDisplaySurvivesRelaunch(display: WorkflowMenuBarDisplay) {
        let defaults = WorkflowMenuBarDefaults()
        let first = TallyStore(defaults: defaults) { throw CancellationError() }
        // Set the opposite first so saving the default is tested too.
        first.menuBarDisplay = display == .today ? .monthProgress : .today
        first.menuBarDisplay = display
        let relaunched = TallyStore(defaults: defaults) { throw CancellationError() }
        #expect(relaunched.menuBarDisplay == display)
        #expect(defaults.string(forKey: "workflowMenuBarDisplay") == display.rawValue)
    }

    @Test func switchingDisplayAndMetricUsesTheirGoalsWithoutFetchingAgain() async {
        let now = date()
        let snapshot = snapshot(at: now)
        let script = WorkflowMenuBarScript(snapshot)
        let store = TallyStore(defaults: WorkflowMenuBarDefaults()) { try await script.next() }
        await store.refresh()
        store.goal = 100
        let pace = store.pace(at: now)
        store.menuBarDisplay = .monthProgress
        #expect(store.menuBarTitle(at: now) == "42/100")
        #expect(store.pace(at: now) == pace)
        store.goal = 1200
        #expect(store.menuBarTitle(at: now) == "\(42.formatted())/\(1200.formatted())")
        store.metric = .merged
        store.goal = 12
        #expect(store.menuBarTitle(at: now) == "10/12")
        store.menuBarDisplay = .today
        #expect(store.menuBarTitle(at: now) == "1")
        #expect(store.goal == 12)
        #expect(store.metric == .merged)
        store.metric = .opened
        store.menuBarDisplay = .monthProgress
        #expect(store.menuBarTitle(at: now) == "\(42.formatted())/\(1200.formatted())")
        #expect(await script.calls == 1)
    }

    @Test func theNumberUsesTheChosenDisplaysAchievement() async {
        let now = date()
        let snapshot = snapshot(at: now)
        let store = TallyStore(defaults: WorkflowMenuBarDefaults()) { snapshot }
        await store.refresh()
        store.goal = 45
        #expect(store.menuBarBeatsPace(at: now))
        #expect(store.menuBarNumberIsGreen(at: now))
        store.menuBarDisplay = .monthProgress
        #expect(!store.menuBarNumberIsGreen(at: now))
        store.goal = 42
        #expect(store.menuBarNumberIsGreen(at: now))
        store.goal = 41
        #expect(store.menuBarNumberIsGreen(at: now))
        store.goal = 60
        store.menuBarDisplay = .today
        #expect(!store.menuBarNumberIsGreen(at: now))
        // A goal reached earlier this month is green even when today is quiet.
        let quietSnapshot = self.snapshot(at: now, before: 42, today: 0)
        let quiet = TallyStore(defaults: WorkflowMenuBarDefaults()) { quietSnapshot }
        await quiet.refresh()
        quiet.goal = 42
        quiet.menuBarDisplay = .monthProgress
        #expect(quiet.menuBarNumberIsGreen(at: now))
        #expect(!quiet.menuBarBeatsPace(at: now))
    }

    @Test(arguments: WorkflowMenuBarDisplay.allCases)
    func missingOrOldMonthNumbersKeepTheDash(display: WorkflowMenuBarDisplay) async {
        let now = date()
        let snapshot = snapshot(at: now)
        let store = TallyStore(defaults: WorkflowMenuBarDefaults()) { snapshot }
        store.menuBarDisplay = display
        #expect(store.menuBarTitle(at: now) == "–")
        #expect(!store.menuBarNumberIsGreen(at: now))
        await store.refresh()
        let nextMonth = date(month: 12, day: 1)
        #expect(store.menuBarTitle(at: nextMonth) == "–")
        #expect(!store.menuBarNumberIsGreen(at: nextMonth))
    }

    @Test func anEmptyCurrentMonthShowsZeroProgress() async {
        let now = date()
        let snapshot = snapshot(at: now, before: 0, today: 0)
        let store = TallyStore(defaults: WorkflowMenuBarDefaults()) { snapshot }
        store.goal = 100
        store.menuBarDisplay = .monthProgress
        await store.refresh()
        #expect(store.menuBarTitle(at: now) == "0/100")
        #expect(!store.menuBarNumberIsGreen(at: now))
    }

    @Test func voiceOverKeepsDailyAndMonthlyContextInBothDisplays() async {
        let now = Date()
        let snapshot = snapshot(at: now, before: 0)
        let store = TallyStore(defaults: WorkflowMenuBarDefaults()) { snapshot }
        await store.refresh()
        store.goal = 100
        let dailyLabel = store.menuBarAccessibilityLabel
        #expect(dailyLabel.hasPrefix("2 today. 2 of 100 PRs opened."))
        store.menuBarDisplay = .monthProgress
        #expect(store.menuBarAccessibilityLabel == dailyLabel)
        store.metric = .merged
        store.goal = 20
        #expect(store.menuBarAccessibilityLabel.hasPrefix("1 today, beating the daily pace. 10 of 20 PRs merged."))
    }

    @Test func failedRefreshKeepsMonthlyProgressAndStaleVoiceOverContext() async {
        let now = Date()
        let snapshot = snapshot(at: now, fetchedAt: now.addingTimeInterval(-20 * 60))
        let script = WorkflowMenuBarScript(snapshot)
        let store = TallyStore(defaults: WorkflowMenuBarDefaults()) { try await script.next() }
        store.menuBarDisplay = .monthProgress
        store.goal = 100
        await store.refresh()
        store.clock = { now }
        await store.refresh()
        store.clock = { now.addingTimeInterval(120) }
        await store.refresh()
        #expect(store.menuBarTitle(at: now) == "42/100")
        #expect(store.menuBarIsStale)
        #expect(store.menuBarAccessibilityLabel.contains(". Not updating since "))
    }

    @Test func theMenuBarObservesDisplayGoalMetricAndSnapshotChanges() async {
        let now = date()
        let snapshot = snapshot(at: now)
        let script = WorkflowMenuBarScript(snapshot, second: self.snapshot(at: now, today: 3))
        let store = TallyStore(defaults: WorkflowMenuBarDefaults()) { try await script.next() }
        func watch() -> WorkflowMenuBarRedraw {
            let redraw = WorkflowMenuBarRedraw()
            withObservationTracking {
                _ = store.menuBarTitle(at: now)
                _ = store.menuBarNumberIsGreen(at: now)
            } onChange: { redraw.fired = true }
            return redraw
        }
        await store.refresh()
        let display = watch()
        store.menuBarDisplay = .monthProgress
        #expect(display.fired)
        let goal = watch()
        store.goal = 50
        #expect(goal.fired)
        let metric = watch()
        store.metric = .merged
        #expect(metric.fired)
        store.metric = .opened
        let refreshed = watch()
        await store.refresh()
        #expect(refreshed.fired)
        #expect(store.menuBarTitle(at: now) == "43/50")
    }

}

private actor WorkflowMenuBarScript {
    private let snapshot: MonthSnapshot
    private let second: MonthSnapshot?
    private(set) var calls = 0
    init(_ snapshot: MonthSnapshot, second: MonthSnapshot? = nil) {
        self.snapshot = snapshot
        self.second = second
    }
    func next() throws -> MonthSnapshot {
        calls += 1
        if calls == 2, let second { return second }
        guard calls == 1 else { throw CancellationError() }
        return snapshot
    }
}

private final class WorkflowMenuBarRedraw: @unchecked Sendable {
    var fired = false
}
