import Foundation
import Testing
import TallyCore
@testable import TallyUI

private struct Offline: LocalizedError {
    var errorDescription: String? { "Offline" }
}

private func snapshot(opened: Int, at now: Date = Date()) -> MonthSnapshot {
    let prs = (0..<opened).map {
        PullRequest(
            id: "\($0)", title: "", url: URL(string: "https://github.com")!, createdAt: now, mergedAt: nil,
            repository: .init(nameWithOwner: "me/app")
        )
    }
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: now), opened: prs, merged: [], totalContributions: 0, fetchedAt: now
    )
}

private func november(_ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
}

private func monthSnapshot(openedByDay: [(Date, Int)], at now: Date) -> MonthSnapshot {
    let prs = openedByDay.flatMap { day, count in
        (0..<count).map {
            PullRequest(
                id: "\(day)-\($0)", title: "", url: URL(string: "https://github.com")!, createdAt: day, mergedAt: nil,
                repository: .init(nameWithOwner: "me/app")
            )
        }
    }
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: now), opened: prs, merged: [], totalContributions: 0, fetchedAt: now
    )
}

/// Replays results in order, repeating the last.
private actor Script {
    private var results: [Result<MonthSnapshot, Error>]
    private(set) var calls = 0
    init(_ results: [Result<MonthSnapshot, Error>]) { self.results = results }
    func next() throws -> MonthSnapshot {
        calls += 1
        return try (results.count > 1 ? results.removeFirst() : results[0]).get()
    }
}

private func freshDefaults() -> UserDefaults {
    let name = "PRTallyTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
@Suite struct TallyStoreTests {
    @Test func settingsDefaultToAThousandOpenedPRs() {
        let store = TallyStore(defaults: freshDefaults()) { snapshot(opened: 0) }
        #expect(store.goal == 1000)
        #expect(store.metric == .opened)
        #expect(store.refreshMinutes == 15)
    }

    @Test func settingsSurviveARestart() {
        let defaults = freshDefaults()
        let store = TallyStore(defaults: defaults) { snapshot(opened: 0) }
        store.goal = 750
        store.metric = .merged
        store.refreshMinutes = 5
        let restarted = TallyStore(defaults: defaults) { snapshot(opened: 0) }
        #expect(restarted.goal == 750)
        #expect(restarted.metric == .merged)
        #expect(restarted.refreshMinutes == 5)
    }

    @Test func goalCannotDropBelowOne() {
        let store = TallyStore(defaults: freshDefaults()) { snapshot(opened: 0) }
        store.goal = 0
        #expect(store.goal == 1)
        store.goal = -5
        #expect(store.goal == 1)
    }

    @Test func metricChoosesWhatTheMenuBarCounts() async {
        let now = Date()
        let pr = PullRequest(
            id: "m", title: "", url: URL(string: "https://github.com")!, createdAt: now, mergedAt: now,
            repository: .init(nameWithOwner: "me/app")
        )
        let store = TallyStore(defaults: freshDefaults()) {
            MonthSnapshot(
                login: "me", window: MonthWindow(containing: now), opened: [], merged: [pr, pr],
                totalContributions: 0, fetchedAt: now
            )
        }
        await store.refresh()
        #expect(store.menuBarTitle(at: now) == "0")
        store.metric = .merged
        #expect(store.menuBarTitle(at: now) == "2")
    }

    @Test func menuBarNumberCountsTodayNotTheMonth() async {
        let now = november(16)
        let store = TallyStore(defaults: freshDefaults()) {
            monthSnapshot(openedByDay: [(november(3), 40), (now, 2)], at: now)
        }
        #expect(store.menuBarTitle(at: now) == "–")
        await store.refresh()
        #expect(store.menuBarTitle(at: now) == "2")
        #expect(store.pace(at: now)?.count == 42)
    }

    @Test func menuBarNumberBeatsPaceOnlyWhenTodayPassesTheDailyQuota() async {
        let now = november(16)
        let store = TallyStore(defaults: freshDefaults()) {
            monthSnapshot(openedByDay: [(now, 31)], at: now)
        }
        store.goal = 900
        #expect(!store.menuBarBeatsPace(at: now))
        await store.refresh()
        #expect(store.menuBarBeatsPace(at: now))
        store.goal = 930
        #expect(!store.menuBarBeatsPace(at: now))
    }

    @Test func menuBarAccessibilityLabelReadsTodayThenTheMonth() async {
        let store = TallyStore(defaults: freshDefaults()) { snapshot(opened: 74) }
        #expect(store.menuBarAccessibilityLabel == "PR Tally, loading")
        await store.refresh()
        #expect(store.menuBarAccessibilityLabel.hasPrefix("74 today, beating the daily pace. 74 of 1,000 PRs opened."))
        store.goal = 100_000
        #expect(store.menuBarAccessibilityLabel.hasPrefix("74 today. 74 of 100,000 PRs opened."))
    }

    @Test func menuBarImageKeepsItsColorsAndMakesRoomForAGreenNumber() {
        let ring = MenuBarGlyph.image(for: nil)
        let short = MenuBarGlyph.image(for: nil, greenTitle: "4")
        let long = MenuBarGlyph.image(for: nil, greenTitle: "1,234")
        #expect(!ring.isTemplate)
        #expect(!short.isTemplate)
        #expect(short.size.width > ring.size.width)
        #expect(long.size.width > short.size.width)
    }

    @Test func ringMatchesPaceStatus() {
        #expect(MenuBarGlyph.color(for: .behind) == .systemOrange)
        #expect(MenuBarGlyph.color(for: .ahead) == .systemGreen)
        #expect(MenuBarGlyph.color(for: .onPace) == .systemGreen)
        #expect(MenuBarGlyph.color(for: .goalHit) == .systemGreen)
    }

    @Test func failedRefreshKeepsLastNumbersAndRecoveryClearsTheError() async {
        let script = Script([.success(snapshot(opened: 5)), .failure(Offline()), .success(snapshot(opened: 6))])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        await store.refresh()
        await store.refresh()
        #expect(store.count == 5)
        #expect(store.errorMessage == "Offline")
        await store.refresh()
        #expect(store.count == 6)
        #expect(store.errorMessage == nil)
    }

    @Test func openingThePopoverSkipsRefreshWhenNumbersAreFresh() async {
        let now = Date()
        let script = Script([.success(snapshot(opened: 1, at: now))])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        await store.refreshIfStale(now: now)
        await store.refreshIfStale(now: now.addingTimeInterval(30))
        #expect(await script.calls == 1)
        await store.refreshIfStale(now: now.addingTimeInterval(61))
        #expect(await script.calls == 2)
    }
}
