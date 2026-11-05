import Foundation
import Observation
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

private func calendar(in zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

/// A snapshot counted in `calendar`'s zone, whatever zone this machine is in.
private func snapshot(opened: Int, at now: Date, in calendar: Calendar) -> MonthSnapshot {
    let prs = (0..<opened).map {
        PullRequest(
            id: "\($0)", title: "", url: URL(string: "https://github.com")!, createdAt: now, mergedAt: nil,
            repository: .init(nameWithOwner: "me/app")
        )
    }
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: now, calendar: calendar), opened: prs, merged: [],
        totalContributions: 0, fetchedAt: now
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

private func freshCache() -> (cache: SnapshotCache, url: URL) {
    let url = FileManager.default.temporaryDirectory.appending(path: "PRTallyTests/\(UUID().uuidString)/snapshot.json")
    return (SnapshotCache(url: url), url)
}

/// Holds a fetch open until the test lets it finish.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var started = 0
    func pass() async {
        started += 1
        if !open { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private let october31 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 18))!

/// Serialized because the notification tests post on the shared center, which every started store hears.
@MainActor
@Suite(.serialized) struct TallyStoreTests {
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

    @Test func lastGoodNumbersSurviveARestartWithNoNetwork() async {
        let (cache, _) = freshCache()
        let now = Date()
        let pr = PullRequest(
            id: "a", title: "Fix it", url: URL(string: "https://github.com/me/app/pull/1")!, createdAt: now,
            mergedAt: now, repository: .init(nameWithOwner: "me/app")
        )
        let original = MonthSnapshot(
            login: "me", window: MonthWindow(containing: now), opened: [pr, pr], merged: [pr], totalContributions: 9,
            fetchedAt: now
        )
        let first = TallyStore(defaults: freshDefaults(), cache: cache) { original }
        await first.refresh()

        let restarted = TallyStore(defaults: freshDefaults(), cache: cache) { throw Offline() }
        #expect(restarted.menuBarTitle(at: now) == "2")
        #expect(restarted.pace(at: now)?.count == 2)
        await restarted.refresh()
        #expect(restarted.errorMessage == "Offline")
        let restored = restarted.snapshot
        #expect(restored?.login == "me")
        #expect(restored?.opened == original.opened)
        #expect(restored?.merged == original.merged)
        #expect(restored?.totalContributions == 9)
        #expect(restored?.fetchedAt == now)
        #expect(restored?.window.start == original.window.start)
        #expect(restored?.window.end == original.window.end)
    }

    @Test func failedRefreshLeavesTheSavedNumbersAlone() async {
        let (cache, _) = freshCache()
        let script = Script([.success(snapshot(opened: 5)), .failure(Offline())])
        let store = TallyStore(defaults: freshDefaults(), cache: cache) { try await script.next() }
        await store.refresh()
        await store.refresh()
        #expect(cache.load()?.opened.count == 5)
    }

    @Test func unreadableCacheStartsEmptyAndRecovers() async throws {
        let (cache, url) = freshCache()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = TallyStore(defaults: freshDefaults(), cache: cache) { snapshot(opened: 3) }
        #expect(store.snapshot == nil)
        await store.refresh()
        #expect(cache.load()?.opened.count == 3)
    }

    @Test func savedNumbersAreReadableOnlyByThisUser() throws {
        let (cache, url) = freshCache()
        cache.save(snapshot(opened: 1))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func lastMonthsNumbersAreNotPassedOffAsThisMonths() async {
        let now = november(1)
        let store = TallyStore(defaults: freshDefaults()) { snapshot(opened: 842, at: october31) }
        await store.refresh()
        #expect(store.snapshot != nil)
        #expect(store.currentSnapshot(at: now) == nil)
        #expect(store.pace(at: now) == nil)
        #expect(store.menuBarTitle(at: now) == "–")
        #expect(!store.menuBarBeatsPace(at: now))
        #expect(store.lastMonthSummary(at: now) == "Last count for October: 842 PRs opened, as of Oct 31.")

        #expect(store.currentSnapshot(at: october31) != nil)
        #expect(store.lastMonthSummary(at: october31) == nil)
    }

    @Test func updatedTextAddsTheDateOnceItIsNoLongerToday() async {
        let store = TallyStore(defaults: freshDefaults()) { snapshot(opened: 1, at: october31) }
        #expect(store.updatedText(at: october31) == nil)
        await store.refresh()
        let time = october31.formatted(date: .omitted, time: .shortened)
        #expect(store.updatedText(at: october31) == "Updated \(time)")
        let nextDay = store.updatedText(at: october31.addingTimeInterval(86_400))
        #expect(nextDay?.hasPrefix("Updated Oct 31") == true)
    }

    @Test func dayChangeRedrawsTheMenuBarEvenWhenTheRefreshFails() async {
        let store = TallyStore(defaults: freshDefaults()) { throw Offline() }
        let redrawn = Redraw()
        withObservationTracking {
            _ = store.menuBarTitle()
        } onChange: {
            redrawn.fired = true
        }
        await store.calendarDayChanged()
        #expect(redrawn.fired)
    }

    @Test func dayChangeNotificationRefreshes() async throws {
        let script = Script([.success(snapshot(opened: 1))])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        store.start()
        while await script.calls < 1 { try await Task.sleep(for: .milliseconds(10)) }
        // The watcher subscribes on its own task, so keep posting until it hears one.
        for _ in 0..<200 where await script.calls < 2 {
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await script.calls >= 2)
    }

    // MARK: Time zone changes

    /// `Calendar`'s own Codable form says "the current calendar" for `Calendar.current`, which comes back as
    /// whatever this launch's zone is. The zone has to be restored from what was saved instead.
    @Test(arguments: ["Asia/Tokyo", "America/New_York", "Pacific/Honolulu", "Pacific/Auckland"])
    func savedMonthComesBackInTheZoneItWasSavedIn(zone: String) throws {
        let saved = calendar(in: zone)
        // Just past local midnight, so that any other zone's reading of the window start is in another month.
        let now = date(11, 1, 0, 30, in: saved)
        let (cache, url) = freshCache()
        cache.save(snapshot(opened: 3))  // The real app's calendar: Calendar.current.
        var file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        // Stand in for the file having been saved while the system was in `zone`.
        file["timeZoneIdentifier"] = zone
        file["monthStart"] = date(11, 1, 0, in: saved).timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: file).write(to: url)

        let window = try #require(cache.load()).window
        #expect(window.calendar.timeZone.identifier == zone)
        #expect(window.calendar.identifier == .gregorian)
        #expect(window.start == date(11, 1, 0, in: saved))
        #expect(window.end == date(12, 1, 0, in: saved))
        #expect(window.calendar.component(.month, from: window.start) == 11)
        #expect(window.contains(now))
    }

    @Test func relaunchInANewZoneStillHasTheMonthTheNumbersWereCountedFor() throws {
        let tokyo = calendar(in: "Asia/Tokyo")
        let newYork = calendar(in: "America/New_York")
        let (cache, _) = freshCache()
        cache.save(snapshot(opened: 40, at: date(11, 3, 12, in: tokyo), in: tokyo))

        let store = TallyStore(defaults: freshDefaults(), cache: cache) { throw Offline() }
        let november5 = date(11, 5, 12, in: newYork)
        #expect(store.currentSnapshot(at: november5, calendar: newYork)?.opened.count == 40)
        #expect(store.lastMonthSummary(at: november5) == nil)
        let november1 = date(11, 1, 0, 30, in: tokyo)
        #expect(store.snapshot.map { $0.window.calendar.component(.month, from: $0.window.start) } == 11)
        #expect(store.currentSnapshot(at: november1, calendar: newYork) == nil)
    }

    @Test func fileFromTheOldFormatOrWithUnknownNamesLoadsAsNothing() throws {
        let (cache, url) = freshCache()
        cache.save(snapshot(opened: 1))
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(cache.load() != nil)

        func writeAndLoad(_ change: (inout [String: Any]) -> Void) throws -> MonthSnapshot? {
            var edited = saved
            change(&edited)
            try JSONSerialization.data(withJSONObject: edited).write(to: url)
            return cache.load()
        }
        #expect(try writeAndLoad { $0["timeZoneIdentifier"] = "Mars/Olympus_Mons" } == nil)
        #expect(try writeAndLoad { $0["calendarIdentifier"] = ["klingon": [String: String]()] } == nil)
        #expect(try writeAndLoad {
            $0["timeZoneIdentifier"] = nil
            $0["calendarIdentifier"] = nil
            $0["calendar"] = ["identifier": "gregorian", "timeZone": ["identifier": "Asia/Tokyo"]]
        } == nil)
    }

    @Test func zoneChangeMidMonthKeepsTheNumbersCurrent() async {
        let newYork = calendar(in: "America/New_York")
        let tokyo = calendar(in: "Asia/Tokyo")
        let fetched = date(11, 15, 12, in: tokyo)
        let store = TallyStore(defaults: freshDefaults()) { snapshot(opened: 7, at: fetched, in: tokyo) }
        await store.refresh()
        // 22:00 on the 14th in New York: a different day, the same month.
        #expect(store.currentSnapshot(at: fetched, calendar: newYork)?.opened.count == 7)
        #expect(store.currentSnapshot(at: fetched, calendar: tokyo)?.opened.count == 7)
    }

    @Test func movingEastIntoTheNextMonthShowsWaitingNotTheEndedMonth() async {
        let newYork = calendar(in: "America/New_York")
        let tokyo = calendar(in: "Asia/Tokyo")
        let fetched = date(10, 31, 22, in: newYork)
        let store = TallyStore(defaults: freshDefaults()) { snapshot(opened: 842, at: fetched, in: newYork) }
        await store.refresh()
        #expect(store.currentSnapshot(at: fetched, calendar: newYork)?.opened.count == 842)
        // Still inside the window's instants, but already November on the wall.
        #expect(store.currentSnapshot(at: fetched, calendar: tokyo) == nil)
    }

    @Test func movingWestIntoTheMonthBeforeShowsWaitingNotTheNewMonth() async {
        let newYork = calendar(in: "America/New_York")
        let tokyo = calendar(in: "Asia/Tokyo")
        let fetched = date(11, 1, 1, in: tokyo)
        let store = TallyStore(defaults: freshDefaults()) { snapshot(opened: 3, at: fetched, in: tokyo) }
        await store.refresh()
        #expect(store.currentSnapshot(at: fetched, calendar: tokyo)?.opened.count == 3)
        #expect(store.currentSnapshot(at: fetched, calendar: newYork) == nil)
    }

    @Test func sameMonthNumberOnTheWallIsNotEnoughWhenNowIsOutsideTheWindow() async {
        let newYork = calendar(in: "America/New_York")
        let tokyo = calendar(in: "Asia/Tokyo")
        let fetched = date(11, 3, 12, in: newYork)
        let store = TallyStore(defaults: freshDefaults()) { snapshot(opened: 5, at: fetched, in: newYork) }
        await store.refresh()
        // 05:00 on Nov 1 in Tokyo is still Oct 31 in New York, before this window opens.
        let beforeTheWindow = date(11, 1, 5, in: tokyo)
        #expect(store.currentSnapshot(at: beforeTheWindow, calendar: tokyo) == nil)
        #expect(store.currentSnapshot(at: date(11, 2, 12, in: tokyo), calendar: tokyo)?.opened.count == 5)
    }

    // MARK: Month labels across a zone change

    /// Names the month the way the popover does: the header, then the waiting caption under it.
    private func labels(
        _ store: TallyStore, at now: Date, in calendar: Calendar
    ) -> (header: String, caption: String?) {
        (store.monthTitle(at: now, calendar: calendar), store.lastMonthSummary(at: now, calendar: calendar))
    }

    @Test(arguments: ["America/New_York", "America/Los_Angeles"])
    func numbersCountedInTokyoKeepTheirMonthInTheHeaderAfterMovingWest(zone: String) async {
        let tokyo = calendar(in: "Asia/Tokyo")
        let west = calendar(in: zone)
        let store = TallyStore(defaults: freshDefaults()) {
            snapshot(opened: 40, at: date(11, 3, 12, in: tokyo), in: tokyo)
        }
        await store.refresh()
        let relaunch = labels(store, at: date(11, 5, 12, in: west), in: west)
        #expect(store.currentSnapshot(at: date(11, 5, 12, in: west), calendar: west)?.opened.count == 40)
        #expect(relaunch.header == "November 2026")
        #expect(relaunch.caption == nil)
        // Same fetch, zone moved the same day: Tokyo's Nov 3 noon is still Nov 2 evening here.
        #expect(labels(store, at: date(11, 3, 12, in: tokyo), in: west).header == "November 2026")
    }

    @Test func waitingNamesTheUsersMonthAndTheCaptionNamesTheWindowsOwn() async {
        let tokyo = calendar(in: "Asia/Tokyo")
        let newYork = calendar(in: "America/New_York")
        let fetched = date(11, 1, 1, in: tokyo)
        let store = TallyStore(defaults: freshDefaults()) { snapshot(opened: 3, at: fetched, in: tokyo) }
        await store.refresh()
        // Oct 31 at noon in New York: the numbers are November's, but it isn't November here yet.
        let now = date(10, 31, 12, in: newYork)
        #expect(store.currentSnapshot(at: now, calendar: newYork) == nil)
        let waiting = labels(store, at: now, in: newYork)
        #expect(waiting.header == "October 2026")
        #expect(waiting.caption == "Last count for November: 3 PRs opened, as of Oct 31.")
    }

    @Test func tokyoDecemberStaysDecemberInTheCaptionWhenReadInLosAngeles() async {
        let tokyo = calendar(in: "Asia/Tokyo")
        let losAngeles = calendar(in: "America/Los_Angeles")
        let fetched = date(12, 31, 20, in: tokyo)
        let store = TallyStore(defaults: freshDefaults()) { snapshot(opened: 9, at: fetched, in: tokyo) }
        await store.refresh()
        let now = date(12, 31, 12, in: losAngeles)
        #expect(store.currentSnapshot(at: now, calendar: losAngeles) == nil)
        let waiting = labels(store, at: now, in: losAngeles)
        #expect(waiting.header == "December 2026")
        #expect(waiting.caption == "Last count for December: 9 PRs opened, as of Dec 31.")
    }

    @Test func sameZoneLabelsAreUnchanged() async {
        let newYork = calendar(in: "America/New_York")
        let store = TallyStore(defaults: freshDefaults()) {
            snapshot(opened: 2, at: date(11, 3, 12, in: newYork), in: newYork)
        }
        await store.refresh()
        let current = labels(store, at: date(11, 5, 12, in: newYork), in: newYork)
        #expect(current.header == "November 2026")
        #expect(current.caption == nil)
        let ended = labels(store, at: date(12, 1, 12, in: newYork), in: newYork)
        #expect(ended.header == "December 2026")
        #expect(ended.caption == "Last count for November: 2 PRs opened, as of Nov 3.")
    }

    @Test func updatedTextTellsTodayByTheClockItPrintsNotTheWindowsZone() async {
        let tokyo = calendar(in: "Asia/Tokyo")
        let local = Calendar.current
        // 23:30 and 00:30 on this machine's wall: two days here, though only an hour apart.
        let fetched = local.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 23, minute: 30))!
        let now = local.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 0, minute: 30))!
        let store = TallyStore(defaults: freshDefaults()) { snapshot(opened: 1, at: fetched, in: tokyo) }
        await store.refresh()
        #expect(store.updatedText(at: now)?.hasPrefix("Updated Nov 2") == true)
    }

    @Test func timeZoneChangeRedrawsAndRefreshes() async throws {
        let script = Script([.success(snapshot(opened: 1))])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        store.start()
        while await script.calls < 1 { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<200 where await script.calls < 2 {
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await script.calls >= 2)
    }

    @Test func timeZoneChangeRedrawsTheMenuBarEvenWhenTheRefreshFails() async throws {
        let store = TallyStore(defaults: freshDefaults()) { throw Offline() }
        store.start()
        let redrawn = Redraw()
        withObservationTracking {
            _ = store.menuBarTitle()
        } onChange: {
            redrawn.fired = true
        }
        for _ in 0..<200 where !redrawn.fired {
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(redrawn.fired)
    }

    @Test func fetchThatSpansMidnightIsFollowedByAFreshOne() async throws {
        let gate = Gate()
        let script = Script([.success(snapshot(opened: 842, at: october31)), .success(snapshot(opened: 2))])
        let store = TallyStore(defaults: freshDefaults()) {
            await gate.pass()
            return try await script.next()
        }
        let inFlight = Task { await store.refresh() }
        while await gate.started < 1 { try await Task.sleep(for: .milliseconds(5)) }
        await store.calendarDayChanged()
        await gate.release()
        await inFlight.value
        #expect(await script.calls == 2)
        #expect(store.currentSnapshot()?.opened.count == 2)
    }
}

private final class Redraw: @unchecked Sendable {
    var fired = false
}
