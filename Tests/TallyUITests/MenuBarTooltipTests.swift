import Foundation
import Testing
import TallyCore
@testable import TallyUI

private final class MenuBarTooltipDefaults: UserDefaults, @unchecked Sendable {
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

@MainActor @Suite struct MenuBarTooltipTests {
    private func november(_ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
    }

    private var window: MonthWindow { MonthWindow(containing: november(16)) }

    private func tooltip(count: Int, goal: Int = 100, today: Int, goalDay: Int? = nil) -> MenuBarTooltip {
        MenuBarTooltip(
            pace: Pace(goal: goal, count: count, window: window, at: november(16)), today: today, metric: .opened,
            window: window, goalDay: goalDay, lastMonth: nil, updated: "Updated 11:58 AM"
        )
    }

    /// `count` PRs opened on the 10th and `today` more on the 16th, all merged on the 16th.
    private func snapshot(count: Int, today: Int) -> MonthSnapshot {
        func prs(_ count: Int, at date: Date) -> [PullRequest] {
            (0..<count).map {
                PullRequest(
                    id: "\(date)-\($0)", title: "", url: URL(string: "https://github.com/me/app/pull/1")!,
                    createdAt: date, mergedAt: november(16), repository: .init(nameWithOwner: "me/app")
                )
            }
        }
        let prs = prs(count, at: november(10)) + prs(today, at: november(16))
        return MonthSnapshot(
            login: "me", window: window, opened: prs, merged: prs, totalContributions: 0, fetchedAt: november(16)
        )
    }

    @Test func behindPaceSaysHowFarWithTheDaysLeftAndWhatTodayStillNeeds() {
        // Halfway through the 16th of 30 days, a steady pace to 100 is at 52. The other 58 over 15 days is 4 a day.
        #expect(tooltip(count: 42, today: 2).lines == [
            "42 of 100 PRs opened in November",
            "10 behind pace · 15 days left",
            "2 today, 2 more for today's share",
            "Updated 11:58 AM",
        ])
    }

    @Test func aGreenTodayNumberIsExplainedByTheDailyQuota() {
        #expect(tooltip(count: 60, today: 5).lines[1...2] == [
            "8 ahead of pace · 15 days left",
            "5 today, over the daily quota of 3.3",
        ])
        // Behind, today's share is more than the quota, so a day can pass one and not the other.
        #expect(tooltip(count: 30, today: 4).lines[1...2] == [
            "22 behind pace · 15 days left",
            "4 today, over the daily quota of 3.3; 1 more for today's share",
        ])
        #expect(tooltip(count: 52, today: 0).lines[1...2] == ["Right on pace · 15 days left", "0 today, 4 more for today's share"])
    }

    @Test func aReachedGoalSaysWhenAndLeavesTheCountdownOut() {
        let reached = tooltip(count: 104, today: 4, goalDay: 9)
        #expect(reached.lines[0...2] == [
            "104 of 100 PRs opened in November", "Goal hit Nov 10 🎉", "4 today, over the daily quota of 3.3",
        ])
        #expect(tooltip(count: 100, today: 0).lines[1] == "Goal hit 🎉")
    }

    @Test func withoutThisMonthsNumbersItSaysWhatThereIs() {
        let rollover = MenuBarTooltip(
            pace: nil, today: 0, metric: .opened, window: nil, goalDay: nil,
            lastMonth: "Last count for October: 87 PRs opened, as of Oct 31.", updated: "Updated Oct 31, 11:58 PM"
        )
        #expect(rollover.text == "Last count for October: 87 PRs opened, as of Oct 31.\nUpdated Oct 31, 11:58 PM")
        let firstLaunch = MenuBarTooltip(
            pace: nil, today: 0, metric: .opened, window: nil, goalDay: nil, lastMonth: nil, updated: nil
        )
        #expect(firstLaunch.text == "No numbers for this month yet")
    }

    @Test func theStoreFollowsTheMetricAndGoalWhicheverNumberTheMenuBarShows() async {
        let now = november(16)
        let snapshot = snapshot(count: 98, today: 3)
        let store = TallyStore(defaults: MenuBarTooltipDefaults()) { snapshot }
        await store.refresh()
        store.goal = 100
        let updated = "Updated \(november(16).formatted(date: .omitted, time: .shortened))"
        #expect(store.menuBarTooltip(at: now) == [
            "101 of 100 PRs opened in November", "Goal hit Nov 16 🎉", "3 today", updated,
        ].joined(separator: "\n"))
        store.menuBarDisplay = .monthProgress
        #expect(store.menuBarTooltip(at: now).hasPrefix("101 of 100 PRs opened in November\nGoal hit Nov 16 🎉"))
        store.metric = .merged
        store.goal = 200
        #expect(store.menuBarTooltip(at: now).hasPrefix("101 of 200 PRs merged in November\n2 behind pace · 15 days left"))
        // Merged reached 50 on the 16th, though the PRs were opened on the 10th.
        store.goal = 50
        #expect(store.menuBarTooltip(at: now).hasPrefix("101 of 50 PRs merged in November\nGoal hit Nov 16 🎉"))
        // Another month's numbers aren't this month's.
        #expect(store.menuBarTooltip(at: november(16).addingTimeInterval(20 * 86_400)).hasPrefix("Last count for November: "))
    }
}
