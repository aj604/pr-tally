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
}
