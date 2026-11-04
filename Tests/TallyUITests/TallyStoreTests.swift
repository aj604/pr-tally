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

@MainActor
@Suite struct TallyStoreTests {
    @Test func menuBarTitleShowsCountAndCompactGoal() async {
        let store = TallyStore { snapshot(opened: 74) }
        #expect(store.menuBarTitle == "–/1k")
        await store.refresh()
        #expect(store.menuBarTitle == "74/1k")
        store.goal = 1500
        #expect(store.menuBarTitle == "74/1.5k")
        store.goal = 250
        #expect(store.menuBarTitle == "74/250")
    }

    @Test func failedRefreshKeepsLastNumbersAndRecoveryClearsTheError() async {
        let script = Script([.success(snapshot(opened: 5)), .failure(Offline()), .success(snapshot(opened: 6))])
        let store = TallyStore { try await script.next() }
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
        let store = TallyStore { try await script.next() }
        await store.refreshIfStale(now: now)
        await store.refreshIfStale(now: now.addingTimeInterval(30))
        #expect(await script.calls == 1)
        await store.refreshIfStale(now: now.addingTimeInterval(61))
        #expect(await script.calls == 2)
    }
}
