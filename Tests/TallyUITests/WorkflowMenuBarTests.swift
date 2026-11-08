import Foundation
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

    private func snapshot(at now: Date) -> MonthSnapshot {
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
            login: "fixture", window: window, opened: prs(40, at: earlier) + prs(2, at: now),
            merged: prs(9, at: earlier) + prs(1, at: now), totalContributions: 0, fetchedAt: now
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
}
