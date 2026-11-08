import Foundation
import Testing
import TallyCore
@testable import TallyUI

private final class WorkflowGoalDefaults: UserDefaults, @unchecked Sendable {
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

@MainActor @Suite struct WorkflowGoalTests {
    private func store(defaults: UserDefaults = WorkflowGoalDefaults()) -> TallyStore {
        TallyStore(defaults: defaults) { throw CancellationError() }
    }

    @Test func eachMetricKeepsItsEditedGoalWhenSwitchingBackAndForth() {
        let store = store()
        store.goal = 40
        store.metric = .merged
        #expect(store.goal == 1000)
        store.goal = 12
        store.metric = .opened
        #expect(store.goal == 40)
        store.metric = .merged
        #expect(store.goal == 12)
        store.metric = .merged
        #expect(store.goal == 12)
    }

    @Test(arguments: PRMetric.allCases)
    func legacySharedGoalSeedsBothMetricsBeforeEitherIsEdited(metric: PRMetric) {
        let defaults = WorkflowGoalDefaults()
        defaults.set(75, forKey: "goal")
        defaults.set(metric.rawValue, forKey: "metric")
        let store = store(defaults: defaults)
        #expect(store.metric == metric)
        #expect(store.goal == 75)
        store.goal = 90
        store.metric = metric == .opened ? .merged : .opened
        #expect(store.goal == 75)
        store.metric = metric
        #expect(store.goal == 90)
    }

    @Test func bothGoalsAndTheSelectedMetricSurviveRelaunch() {
        let defaults = WorkflowGoalDefaults()
        let first = store(defaults: defaults)
        first.goal = 40
        first.metric = .merged
        first.goal = 12
        let relaunched = store(defaults: defaults)
        #expect(relaunched.metric == .merged)
        #expect(relaunched.goal == 12)
        relaunched.metric = .opened
        #expect(relaunched.goal == 40)
        let again = store(defaults: defaults)
        #expect(again.metric == .opened)
        #expect(again.goal == 40)
        again.metric = .merged
        #expect(again.goal == 12)
    }

    @Test(arguments: [0, -5])
    func invalidLegacyGoalsUseTheDefaultForBothMetrics(savedGoal: Int) {
        let defaults = WorkflowGoalDefaults()
        defaults.set(savedGoal, forKey: "goal")
        let store = store(defaults: defaults)
        #expect(store.goal == 1000)
        store.metric = .merged
        #expect(store.goal == 1000)
    }

    @Test func existingMetricGoalsAreNotReplacedByTheLegacyGoal() {
        let defaults = WorkflowGoalDefaults()
        defaults.set(999, forKey: "goal")
        defaults.set(40, forKey: "workflowGoal.opened")
        defaults.set(12, forKey: "workflowGoal.merged")
        let store = store(defaults: defaults)
        #expect(store.goal == 40)
        store.metric = .merged
        #expect(store.goal == 12)
    }

    @Test func clampingAnEditedGoalOnlyChangesTheSelectedMetric() {
        let defaults = WorkflowGoalDefaults()
        let store = store(defaults: defaults)
        store.goal = 40
        store.metric = .merged
        store.goal = -5
        #expect(store.goal == 1)
        store.metric = .opened
        #expect(store.goal == 40)
        let relaunched = self.store(defaults: defaults)
        relaunched.metric = .merged
        #expect(relaunched.goal == 1)
    }

    @Test func paceAndMenuBarQuotaUseTheMatchingGoalWithoutFetchingAgain() async {
        let now = Date()
        let pr = PullRequest(
            id: "1", title: "Fixture", url: URL(string: "https://github.com/me/app/pull/1")!,
            createdAt: now, mergedAt: now, repository: .init(nameWithOwner: "me/app")
        )
        let snapshot = MonthSnapshot(
            login: "me", window: MonthWindow(containing: now), opened: [pr, pr], merged: [pr],
            totalContributions: 0, fetchedAt: now
        )
        let store = TallyStore(defaults: WorkflowGoalDefaults()) { snapshot }
        store.goal = 1000
        await store.refresh()
        #expect(store.pace(at: now)?.goal == 1000)
        #expect(store.pace(at: now)?.count == 2)
        #expect(!store.menuBarBeatsPace(at: now))
        store.metric = .merged
        store.goal = 1
        #expect(store.pace(at: now)?.goal == 1)
        #expect(store.pace(at: now)?.count == 1)
        #expect(store.pace(at: now)?.status == .goalHit)
        #expect(store.menuBarBeatsPace(at: now))
        store.metric = .opened
        #expect(store.pace(at: now)?.goal == 1000)
        #expect(!store.menuBarBeatsPace(at: now))
        store.metric = .merged
        #expect(store.pace(at: now)?.goal == 1)
        #expect(store.menuBarBeatsPace(at: now))
    }
    private func planningSnapshot(at now: Date, before: Int = 450, today: Int = 20) -> MonthSnapshot {
        let window = MonthWindow(containing: now)
        let yesterday = window.calendar.date(byAdding: .day, value: -1, to: now)!
        func prs(_ count: Int, at date: Date) -> [PullRequest] {
            (0..<count).map {
                PullRequest(
                    id: "\(date)-\($0)", title: "Fixture", url: URL(string: "https://github.com/me/app/pull/1")!,
                    createdAt: date, mergedAt: date, repository: .init(nameWithOwner: "me/app")
                )
            }
        }
        return MonthSnapshot(
            login: "fixture", window: window, opened: prs(before, at: yesterday) + prs(today, at: now),
            merged: prs(9, at: yesterday) + prs(1, at: now), totalContributions: 0, fetchedAt: now
        )
    }

    private func planningDate(month: Int = 11, day: Int = 16, year: Int = 2026) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test func editingTheGoalUpdatesThePlanWithoutFetchingAgain() async {
        let now = planningDate()
        let snapshot = planningSnapshot(at: now)
        let store = TallyStore(defaults: WorkflowGoalDefaults()) { snapshot }
        await store.refresh()
        store.goal = 1000
        let initial = store.workflowGoalPlan(at: now)
        #expect(initial.dailyQuota == 1000.0 / 30)
        #expect(initial.remaining == 530)
        #expect(initial.moreToday == 17)
        store.goal = 1200
        let edited = store.workflowGoalPlan(at: now)
        #expect(edited.dailyQuota == 40)
        #expect(edited.remaining == 730)
        #expect(edited.moreToday == 30)
        #expect(store.snapshot == snapshot)
    }

    @Test func switchingMetricsPlansWithTheirOwnGoalsAndCounts() async {
        let now = planningDate()
        let snapshot = planningSnapshot(at: now)
        let store = TallyStore(defaults: WorkflowGoalDefaults()) { snapshot }
        await store.refresh()
        store.goal = 1000
        let opened = store.workflowGoalPlan(at: now)
        store.metric = .merged
        store.goal = 30
        let merged = store.workflowGoalPlan(at: now)
        #expect(merged.metric == .merged)
        #expect(merged.dailyQuota == 1)
        #expect(merged.remaining == 20)
        #expect(merged.moreToday == 1)
        #expect(merged.quotaText == "Average: 1 PRs merged per day this month.")
        #expect(merged.progressText == "20 PRs merged left this month · 1 more today.")
        store.metric = .opened
        #expect(store.workflowGoalPlan(at: now) == opened)
    }

    @Test(arguments: [(2, 2028, 29), (11, 2026, 30), (12, 2026, 31)])
    func missingNumbersStillPreviewTheCalendarQuota(month: Int, year: Int, days: Int) {
        let now = planningDate(month: month, year: year)
        let store = store()
        store.goal = days * 10
        let plan = store.workflowGoalPlan(at: now)
        #expect(plan.dailyQuota == 10)
        #expect(plan.remaining == nil)
        #expect(plan.moreToday == nil)
        #expect(plan.progressText == "Waiting for this month's numbers to calculate what's left.")
    }

    @Test func previousMonthNumbersAreNotTreatedAsCurrentProgress() async {
        let snapshot = planningSnapshot(at: planningDate())
        let store = TallyStore(defaults: WorkflowGoalDefaults()) { snapshot }
        await store.refresh()
        store.goal = 310
        let plan = store.workflowGoalPlan(at: planningDate(month: 12, day: 1))
        #expect(plan.dailyQuota == 10)
        #expect(plan.remaining == nil)
        #expect(plan.moreToday == nil)
        #expect(plan.progressText == "Waiting for this month's numbers to calculate what's left.")
    }

    @Test(arguments: [470, 400])
    func reachingOrPassingTheGoalShowsCompletion(goal: Int) async {
        let now = planningDate()
        let snapshot = planningSnapshot(at: now)
        let store = TallyStore(defaults: WorkflowGoalDefaults()) { snapshot }
        await store.refresh()
        store.goal = goal
        let plan = store.workflowGoalPlan(at: now)
        #expect(plan.remaining == 0)
        #expect(plan.moreToday == 0)
        #expect(plan.progressText == "Goal reached for PRs opened.")
    }

    @Test func todaysShareCanBeCompleteBeforeTheMonthlyGoal() async {
        let now = planningDate()
        let snapshot = planningSnapshot(at: now)
        let store = TallyStore(defaults: WorkflowGoalDefaults()) { snapshot }
        await store.refresh()
        store.goal = 480
        let plan = store.workflowGoalPlan(at: now)
        #expect(plan.remaining == 10)
        #expect(plan.moreToday == 0)
        #expect(plan.progressText == "10 PRs opened left this month · Today's share complete.")
    }

    @Test func theLastDayRequiresAllRemainingPRsToday() async {
        let now = planningDate(day: 30)
        let snapshot = planningSnapshot(at: now)
        let store = TallyStore(defaults: WorkflowGoalDefaults()) { snapshot }
        await store.refresh()
        store.goal = 500
        let plan = store.workflowGoalPlan(at: now)
        #expect(plan.remaining == 30)
        #expect(plan.moreToday == 30)
    }

    @Test func currentMonthWithNoPRsIsProgressRatherThanMissingData() async {
        let now = planningDate()
        let snapshot = planningSnapshot(at: now, before: 0, today: 0)
        let store = TallyStore(defaults: WorkflowGoalDefaults()) { snapshot }
        await store.refresh()
        store.goal = 300
        let plan = store.workflowGoalPlan(at: now)
        #expect(plan.remaining == 300)
        #expect(plan.moreToday == 20)
        #expect(plan.progressText == "300 PRs opened left this month · 20 more today.")
    }
}
