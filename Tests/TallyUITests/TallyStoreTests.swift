import AppKit
import Network
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

private func snapshot(opened: Int, merged: Int, at now: Date = Date()) -> MonthSnapshot {
    let base = snapshot(opened: opened, at: now)
    let prs = (0..<merged).map {
        PullRequest(
            id: "m\($0)", title: "", url: URL(string: "https://github.com")!, createdAt: now, mergedAt: now,
            repository: .init(nameWithOwner: "me/app")
        )
    }
    return MonthSnapshot(
        login: "me", window: base.window, opened: base.opened, merged: prs, totalContributions: 0, fetchedAt: now
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

/// Settings kept in memory. A real `UserDefaults` suite writes ~/Library/Preferences/<suite>.plist as soon
/// as a value is set, and removing the domain afterwards only empties that file.
private final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
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

private func freshDefaults() -> UserDefaults {
    InMemoryDefaults()
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

/// A network that is up and stays up, so started stores don't depend on this machine's.
private let online = NetworkStatus { AsyncStream { $0.yield(true) } }

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

    @Test func cancellingWhoeverAskedLetsTheRefreshFinish() async {
        let gate = Gate()
        let store = TallyStore(defaults: freshDefaults()) {
            await gate.pass()
            try Task.checkCancellation()
            return snapshot(opened: 3)
        }
        let asking = Task { await store.refresh() }
        while await gate.started == 0 { await Task.yield() }
        asking.cancel()
        await gate.release()
        await asking.value
        #expect(store.errorMessage == nil)
        #expect(store.count == 3)
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

    @Test func menuBarFadesWhenRefreshesKeepFailingAnIntervalAfterTheLastNumbers() async {
        let fetchedAt = Date().addingTimeInterval(-20 * 60)
        let script = Script([
            .success(snapshot(opened: 5, at: fetchedAt)), .failure(Offline()), .failure(Offline()), .failure(Offline()),
            .success(snapshot(opened: 6)),
        ])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        let clock = TestClock(store)
        await store.refresh()
        #expect(!store.menuBarIsStale)
        await store.refresh()
        #expect(!store.menuBarIsStale)
        clock.advance(60)
        await store.refresh()
        #expect(!store.menuBarIsStale)
        clock.advance(60)
        await store.refresh()
        #expect(store.menuBarIsStale)
        let time = fetchedAt.formatted(date: .omitted, time: .shortened)
        #expect(store.menuBarAccessibilityLabel.hasSuffix(". Not updating since \(time)"))
        await store.refresh()
        #expect(!store.menuBarIsStale)
        #expect(!store.menuBarAccessibilityLabel.contains("Not updating"))
    }

    @Test func aFailureSoonAfterTheLastNumbersLeavesTheMenuBarAlone() async {
        let fetchedAt = Date().addingTimeInterval(-10 * 60)
        let script = Script([.success(snapshot(opened: 5, at: fetchedAt)), .failure(Offline())])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        let clock = TestClock(store)
        await store.refresh()
        await store.refresh()
        clock.advance(120)
        await store.refresh()
        #expect(store.errorMessage == "Offline")
        #expect(!store.menuBarIsStale)
        store.refreshMinutes = 5
        #expect(store.menuBarIsStale)
    }

    /// The schedule's own try comes just over an interval after the numbers were fetched, so one failure there
    /// is the minute-long blip its retry is for.
    @Test func aFailedScheduledRefreshLeavesTheMenuBarAloneForItsRetry() async {
        let fetchedAt = Date().addingTimeInterval(-(15 * 60 + 5))
        let script = Script([.success(snapshot(opened: 5, at: fetchedAt)), .failure(Offline())])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        await store.refresh()
        await store.refreshIfStale()
        #expect(await script.calls == 2)
        #expect(!store.menuBarIsStale)
    }

    /// Waking runs the overdue scheduled try at once, often before the network is up. Numbers from last night are
    /// long past due, but that try and its retry get the same two minutes as any other.
    @Test func aFailureOnWakingHoursLaterLeavesTheMenuBarAloneForItsRetries() async {
        let script = Script([.success(snapshot(opened: 5, at: Date().addingTimeInterval(-8 * 3600))), .failure(Offline())])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        let clock = TestClock(store)
        await store.refresh()
        await store.refresh()
        #expect(!store.menuBarIsStale)
        clock.advance(60)
        await store.refresh()
        #expect(!store.menuBarIsStale)
        clock.advance(60)
        await store.refresh()
        #expect(store.menuBarIsStale)
    }

    @Test func aGoodRefreshStartsTheTwoMinutesOver() async {
        let lastNight = Date().addingTimeInterval(-8 * 3600)
        let script = Script([
            .success(snapshot(opened: 5, at: lastNight)), .failure(Offline()), .success(snapshot(opened: 5, at: lastNight)),
            .failure(Offline()),
        ])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        let clock = TestClock(store)
        await store.refresh()
        await store.refresh()
        clock.advance(60)
        await store.refresh()
        clock.advance(120)
        await store.refresh()
        #expect(store.errorMessage == "Offline")
        #expect(!store.menuBarIsStale)
    }

    @Test func waitingForTheNetworkFadesOldNumbersUntilItReturns() async {
        let script = Script([
            .success(snapshot(opened: 5, at: Date().addingTimeInterval(-25 * 60))), .success(snapshot(opened: 6)),
        ])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        let clock = TestClock(store)
        await store.refresh()
        await store.networkChanged(isOnline: false)
        await store.refreshIfStale()
        #expect(!store.menuBarIsStale)
        clock.advance(120)
        await store.refreshIfStale()
        #expect(store.menuBarIsStale)
        await store.networkChanged(isOnline: true)
        #expect(store.count == 6)
        #expect(!store.menuBarIsStale)
    }

    @Test func withNoNumbersTheDashFadesOnceRefreshesHaveFailedForTwoMinutes() async {
        let store = TallyStore(defaults: freshDefaults()) { throw Offline() }
        let clock = TestClock(store)
        await store.refresh()
        clock.advance(60)
        await store.refresh()
        #expect(!store.menuBarIsStale)
        #expect(store.menuBarAccessibilityLabel == "PR Tally, loading")
        clock.advance(60)
        await store.refresh()
        #expect(store.menuBarIsStale)
        #expect(store.menuBarTitle() == "–")
        #expect(store.menuBarAccessibilityLabel == "PR Tally, not updating")
    }

    /// A new month that can't be fetched shows "–" like one that is loading, so it fades and says when the
    /// numbers last updated.
    @Test func lastMonthsNumbersFadeTheDashAndSayWhenTheyLastUpdated() async {
        let (cache, _) = freshCache()
        cache.save(snapshot(opened: 40, at: october31))
        let store = TallyStore(defaults: freshDefaults(), cache: cache) { throw Offline() }
        let clock = TestClock(store)
        await store.refresh()
        clock.advance(120)
        await store.refresh()
        #expect(store.menuBarTitle() == "–")
        #expect(store.menuBarIsStale)
        let time = october31.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        #expect(store.menuBarAccessibilityLabel == "PR Tally, not updating since \(time)")
    }

    /// Nothing else changes as a failing refresh is retried, yet each retry finds the numbers older.
    @Test func eachFailedRetryRedrawsTheMenuBar() async {
        let script = Script([.success(snapshot(opened: 5)), .failure(Offline())])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        await store.refresh()
        await store.refresh()
        let redrawn = Redraw()
        withObservationTracking {
            _ = store.menuBarIsStale
        } onChange: {
            redrawn.fired = true
        }
        await store.refresh()
        #expect(redrawn.fired)
    }

    @Test func fadedMenuBarImageCarriesTheNumberAtReducedOpacity() {
        let window = MonthWindow(containing: Date())
        let pace = Pace(goal: 10, count: 6, window: window, at: window.start.addingTimeInterval(86_400))
        let ring = MenuBarGlyph.image(for: pace)
        let faded = MenuBarGlyph.fadedImage(for: pace, title: "12")
        #expect(!faded.isTemplate)
        #expect(faded.size.width > ring.size.width)
        #expect(maxAlpha(of: ring) > 0.9)
        #expect(maxAlpha(of: faded) < 0.5)
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
        let store = TallyStore(defaults: freshDefaults(), network: online) { try await script.next() }
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
        let store = TallyStore(defaults: freshDefaults(), network: online) { try await script.next() }
        store.start()
        while await script.calls < 1 { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<200 where await script.calls < 2 {
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await script.calls >= 2)
    }

    @Test func timeZoneChangeRedrawsTheMenuBarEvenWhenTheRefreshFails() async throws {
        let store = TallyStore(defaults: freshDefaults(), network: online) { throw Offline() }
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

    // MARK: Network

    @Test func openingThePopoverOfflineWaitsForTheNetworkInsteadOfFailing() async {
        let script = Script([.success(snapshot(opened: 3))])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        await store.networkChanged(isOnline: false)
        await store.refreshIfStale()
        #expect(await script.calls == 0)
        #expect(store.errorMessage == TallyStore.offlineMessage)

        await store.networkChanged(isOnline: true)
        #expect(await script.calls == 1)
        #expect(store.errorMessage == nil)
        #expect(store.count == 3)
    }

    @Test func aRefreshThatFailedIsRetriedTheMomentTheNetworkReturns() async {
        let script = Script([.failure(Offline()), .success(snapshot(opened: 2))])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        await store.refresh()
        #expect(store.errorMessage == "Offline")
        await store.networkChanged(isOnline: false)
        #expect(await script.calls == 1)

        await store.networkChanged(isOnline: true)
        #expect(await script.calls == 2)
        #expect(store.errorMessage == nil)
        #expect(store.count == 2)
    }

    @Test func aFetchThatFailsAsTheNetworkReturnsIsTriedAgain() async throws {
        let gate = Gate()
        let script = Script([.failure(Offline()), .success(snapshot(opened: 2))])
        let store = TallyStore(defaults: freshDefaults()) {
            await gate.pass()
            return try await script.next()
        }
        await store.networkChanged(isOnline: false)
        let inFlight = Task { await store.refresh() }
        while await gate.started < 1 { try await Task.sleep(for: .milliseconds(5)) }
        await store.networkChanged(isOnline: true)
        await gate.release()
        await inFlight.value
        #expect(await script.calls == 2)
        #expect(store.errorMessage == nil)
        #expect(store.count == 2)
    }

    @Test func aFetchThatFailsAfterTheNetworkDropsAndReturnsIsTriedAgain() async throws {
        let gate = Gate()
        let script = Script([.failure(Offline()), .success(snapshot(opened: 3))])
        let store = TallyStore(defaults: freshDefaults()) {
            await gate.pass()
            return try await script.next()
        }
        let inFlight = Task { await store.refreshIfStale() }
        while await gate.started < 1 { try await Task.sleep(for: .milliseconds(5)) }
        await store.networkChanged(isOnline: false)
        await store.networkChanged(isOnline: true)
        await gate.release()
        await inFlight.value
        #expect(await script.calls == 2)
        #expect(store.count == 3)
    }

    @Test func aPathThatConnectsOnDemandCountsAsOnline() {
        #expect(NetworkStatus.isUsable(.satisfied))
        #expect(NetworkStatus.isUsable(.requiresConnection))
        #expect(!NetworkStatus.isUsable(.unsatisfied))
    }

    @Test func theNetworkComingBackDoesNotRefetchNumbersNothingWaitedFor() async {
        let script = Script([.success(snapshot(opened: 1))])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        await store.refresh()
        await store.networkChanged(isOnline: false)
        await store.networkChanged(isOnline: true)
        #expect(await script.calls == 1)
    }

    /// The system re-reports a working network whenever an interface changes, which isn't the network coming back.
    @Test func stayingOnlineDoesNotRetryAFailure() async {
        let script = Script([.failure(Offline())])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        await store.refresh()
        await store.networkChanged(isOnline: true)
        await store.networkChanged(isOnline: true)
        #expect(await script.calls == 1)
    }

    @Test func theRefreshButtonStillTriesWhileOffline() async {
        let script = Script([.success(snapshot(opened: 4))])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        await store.networkChanged(isOnline: false)
        await store.refresh()
        #expect(await script.calls == 1)
        #expect(store.count == 4)
    }

    @Test func aDayChangeWhileOfflineWaitsForTheNetwork() async {
        let script = Script([.success(snapshot(opened: 5))])
        let store = TallyStore(defaults: freshDefaults()) { try await script.next() }
        await store.networkChanged(isOnline: false)
        await store.calendarDayChanged()
        #expect(await script.calls == 0)
        #expect(store.errorMessage == TallyStore.offlineMessage)

        await store.networkChanged(isOnline: true)
        #expect(await script.calls == 1)
        #expect(store.count == 5)
    }

    @Test func aStartedStoreRefreshesWhenTheNetworkComesBack() async throws {
        let (changes, network) = AsyncStream.makeStream(of: Bool.self)
        let script = Script([.failure(Offline()), .success(snapshot(opened: 6))])
        let store = TallyStore(defaults: freshDefaults(), network: NetworkStatus { changes }) { try await script.next() }
        store.start()
        while await script.calls < 1 { try await Task.sleep(for: .milliseconds(10)) }
        network.yield(false)
        network.yield(true)
        // The schedule's own retry is a minute away, so only the network coming back can do this.
        for _ in 0..<200 where await script.calls < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await script.calls == 2)
        #expect(store.count == 6)
    }

    @Test func changingTheIntervalDoesNotRefetchNumbersJustFetched() async throws {
        let script = Script([.success(snapshot(opened: 1))])
        let store = TallyStore(defaults: freshDefaults(), network: online) { try await script.next() }
        store.start()
        while await script.calls < 1 { try await Task.sleep(for: .milliseconds(10)) }
        store.refreshMinutes = 5
        try await Task.sleep(for: .milliseconds(200))
        #expect(await script.calls == 1)
    }

    // MARK: Milestones

    @Test func goalReachedBodyCountsTheDaysLeftAfterToday() {
        let metric = PRMetric.opened
        let before = monthSnapshot(openedByDay: [(november(16), 99)], at: november(16))
        let after = monthSnapshot(openedByDay: [(november(16), 103)], at: november(16))
        let milestone = Milestone.goalReached(from: before, to: after, metric: metric, goal: 100, at: november(16))
        #expect(milestone == Milestone(title: "Goal hit 🎉", body: "103 PRs opened in November, with 14 days to spare."))
        let nextToLast = november(29)
        #expect(
            Milestone.goalReached(from: before, to: after, metric: metric, goal: 100, at: nextToLast)?.body
                == "103 PRs opened in November, with a day to spare."
        )
        #expect(
            Milestone.goalReached(from: before, to: after, metric: metric, goal: 100, at: november(30))?.body
                == "103 PRs opened in November, on the last day of the month."
        )
    }

    @Test func goalReachedIsOnlyAnnouncedOnTheRefreshThatCrossesIt() async {
        let sent = Sent()
        let script = Script([
            .success(snapshot(opened: 998)), .success(snapshot(opened: 999)), .success(snapshot(opened: 1000)),
            .success(snapshot(opened: 1004)),
        ])
        let store = TallyStore(defaults: freshDefaults(), notify: { sent.milestones.append($0) }) {
            try await script.next()
        }
        await store.refresh()  // The first numbers have nothing to be compared with.
        await store.refresh()
        #expect(sent.milestones.isEmpty)
        await store.refresh()
        #expect(sent.milestones.count == 1)
        #expect(sent.milestones.first?.title == "Goal hit 🎉")
        #expect(sent.milestones.first?.body.hasPrefix("1,000 PRs opened in ") == true)
        await store.refresh()
        #expect(sent.milestones.count == 1)
    }

    @Test func startingOverTheGoalOrLoweringItBelowTheCountIsNotAnAchievement() async {
        let sent = Sent()
        let script = Script([.success(snapshot(opened: 1200)), .success(snapshot(opened: 1201))])
        let store = TallyStore(defaults: freshDefaults(), notify: { sent.milestones.append($0) }) {
            try await script.next()
        }
        await store.refresh()
        store.goal = 1100
        await store.refresh()
        #expect(sent.milestones.isEmpty)
    }

    @Test func goalReachedWhileTheAppWasClosedIsAnnouncedOnceAfterRelaunch() async {
        let (cache, _) = freshCache()
        let defaults = freshDefaults()
        await TallyStore(defaults: defaults, cache: cache) { snapshot(opened: 990) }.refresh()
        let sent = Sent()
        let relaunched = TallyStore(defaults: defaults, cache: cache, notify: { sent.milestones.append($0) }) {
            snapshot(opened: 1003)
        }
        await relaunched.refresh()
        #expect(sent.milestones.count == 1)

        // A PR dropping out and back in, or another relaunch, doesn't announce the same month's goal again.
        let again = Script([.success(snapshot(opened: 999)), .success(snapshot(opened: 1000))])
        let third = TallyStore(defaults: defaults, cache: cache, notify: { sent.milestones.append($0) }) {
            try await again.next()
        }
        await third.refresh()
        await third.refresh()
        #expect(sent.milestones.count == 1)
    }

    @Test func aGoalRaisedAfterReachingItIsAnnouncedWhenItIsReachedToo() async {
        let sent = Sent()
        let script = Script([
            .success(snapshot(opened: 999)), .success(snapshot(opened: 1000)), .success(snapshot(opened: 1049)),
            .success(snapshot(opened: 1050)), .success(snapshot(opened: 1049)), .success(snapshot(opened: 1051)),
        ])
        let store = TallyStore(defaults: freshDefaults(), notify: { sent.milestones.append($0) }) {
            try await script.next()
        }
        await store.refresh()
        await store.refresh()
        #expect(sent.milestones.count == 1)
        store.goal = 1050
        await store.refresh()
        await store.refresh()
        #expect(sent.milestones.count == 2)
        #expect(sent.milestones.last?.body.hasPrefix("1,050 PRs opened in ") == true)
        // The new goal is still announced only once.
        await store.refresh()
        await store.refresh()
        #expect(sent.milestones.count == 2)
    }

    @Test func reachingTheGoalInTheOtherMetricIsAnnouncedToo() async {
        let sent = Sent()
        let script = Script([
            .success(snapshot(opened: 2, merged: 0)), .success(snapshot(opened: 3, merged: 0)),
            .success(snapshot(opened: 4, merged: 2)), .success(snapshot(opened: 4, merged: 3)),
            .success(snapshot(opened: 5, merged: 3)),
        ])
        let store = TallyStore(defaults: freshDefaults(), notify: { sent.milestones.append($0) }) {
            try await script.next()
        }
        store.goal = 3
        await store.refresh()
        await store.refresh()
        #expect(sent.milestones.count == 1)
        store.metric = .merged
        await store.refresh()
        await store.refresh()
        #expect(sent.milestones.count == 2)
        #expect(sent.milestones.last?.body.hasPrefix("3 PRs merged in ") == true)
        // Switching back finds opened already over the goal, which was announced before.
        store.metric = .opened
        await store.refresh()
        #expect(sent.milestones.count == 2)
    }

    @Test func lastMonthsNumbersAreNotACrossingThisMonth() async {
        let (cache, _) = freshCache()
        cache.save(snapshot(opened: 990, at: october31))
        let sent = Sent()
        let store = TallyStore(defaults: freshDefaults(), cache: cache, notify: { sent.milestones.append($0) }) {
            snapshot(opened: 1000)
        }
        await store.refresh()
        #expect(sent.milestones.isEmpty)
    }

    @Test func notificationsCanBeTurnedOffAndStayOff() async {
        let defaults = freshDefaults()
        let sent = Sent()
        let script = Script([.success(snapshot(opened: 10)), .success(snapshot(opened: 1000))])
        let store = TallyStore(defaults: defaults, notify: { sent.milestones.append($0) }) { try await script.next() }
        #expect(store.notifiesOnGoal)
        store.notifiesOnGoal = false
        await store.refresh()
        await store.refresh()
        #expect(sent.milestones.isEmpty)
        #expect(!TallyStore(defaults: defaults) { snapshot(opened: 0) }.notifiesOnGoal)
    }

    @Test func anotherAccountsNumbersAreNotACrossing() async {
        let other = snapshot(opened: 1000)
        let account = MonthSnapshot(
            login: "someone-else", window: other.window, opened: other.opened, merged: [], totalContributions: 0,
            fetchedAt: other.fetchedAt
        )
        let sent = Sent()
        let script = Script([.success(snapshot(opened: 10)), .success(account), .success(snapshot(opened: 1000))])
        let store = TallyStore(defaults: freshDefaults(), notify: { sent.milestones.append($0) }) {
            try await script.next()
        }
        await store.refresh()
        await store.refresh()
        #expect(sent.milestones.isEmpty)
        // Back on the first account, the goal is still not reached "just now" relative to the other one.
        await store.refresh()
        #expect(sent.milestones.isEmpty)
    }

    @Test func aCrossingWithNotificationsOffIsNotAnnouncedLateWhenTheyComeBackOn() async {
        let sent = Sent()
        let script = Script([
            .success(snapshot(opened: 999)), .success(snapshot(opened: 1000)), .success(snapshot(opened: 998)),
            .success(snapshot(opened: 1001)),
        ])
        let store = TallyStore(defaults: freshDefaults(), notify: { sent.milestones.append($0) }) {
            try await script.next()
        }
        await store.refresh()
        store.notifiesOnGoal = false
        await store.refresh()  // Crosses while off.
        store.notifiesOnGoal = true
        await store.refresh()
        await store.refresh()  // Dips and returns.
        #expect(sent.milestones.isEmpty)
    }

    @Test func goalReachedBodyReadsRightForOnePRAndForMerged() {
        let day = november(16)
        let none = monthSnapshot(openedByDay: [], at: day)
        let one = monthSnapshot(openedByDay: [(day, 1)], at: day)
        #expect(
            Milestone.goalReached(from: none, to: one, metric: .opened, goal: 1, at: day)?.body
                == "1 PR opened in November, with 14 days to spare."
        )
        let pr = PullRequest(
            id: "m", title: "", url: URL(string: "https://github.com")!, createdAt: day, mergedAt: day,
            repository: .init(nameWithOwner: "me/app")
        )
        let merged = MonthSnapshot(
            login: "me", window: MonthWindow(containing: day), opened: [], merged: [pr, pr], totalContributions: 0,
            fetchedAt: day
        )
        let noneMerged = MonthSnapshot(
            login: "me", window: MonthWindow(containing: day), opened: [], merged: [pr], totalContributions: 0,
            fetchedAt: day
        )
        #expect(
            Milestone.goalReached(from: noneMerged, to: merged, metric: .merged, goal: 2, at: day)?.body
                == "2 PRs merged in November, with 14 days to spare."
        )
    }
}

/// The most opaque pixel in `image`, drawn at twice its size.
@MainActor
private func maxAlpha(of image: NSImage) -> CGFloat {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    NSGraphicsContext.restoreGraphicsState()
    var most: CGFloat = 0
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
            most = max(most, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
        }
    }
    return most
}

private final class Redraw: @unchecked Sendable {
    var fired = false
}

/// The store's time for failed refreshes, moved on by hand rather than waiting out real retries.
@MainActor
private final class TestClock {
    private var now = Date()

    init(_ store: TallyStore) {
        store.clock = { [unowned self] in now }
    }

    func advance(_ seconds: TimeInterval) {
        now += seconds
    }
}

/// Collects what the store would have sent as notifications.
@MainActor private final class Sent {
    var milestones: [Milestone] = []
}
