import AppKit
import Observation
import TallyCore

/// Holds the latest numbers and keeps them fresh.
@MainActor
@Observable
public final class TallyStore {
    public typealias Fetch = @Sendable () async throws -> MonthSnapshot

    /// The last good numbers, which can be from a month that has since ended. See `currentSnapshot(at:)`.
    public private(set) var snapshot: MonthSnapshot?
    public private(set) var errorMessage: String?
    public private(set) var isRefreshing = false
    public var goal: Int {
        didSet {
            if goal < 1 { goal = 1 }
            defaults.set(goal, forKey: Keys.goal)
        }
    }
    public var metric: PRMetric {
        didSet { defaults.set(metric.rawValue, forKey: Keys.metric) }
    }
    public var refreshMinutes: Int {
        didSet {
            defaults.set(refreshMinutes, forKey: Keys.refreshMinutes)
            if schedule != nil { startSchedule() }
        }
    }

    private enum Keys {
        static let goal = "goal"
        static let metric = "metric"
        static let refreshMinutes = "refreshMinutes"
    }

    private let fetch: Fetch
    private let defaults: UserDefaults
    private let cache: SnapshotCache?
    private var schedule: Task<Void, Never>?
    private var watchingSystem = false
    /// Read by everything that depends on today's date, so it redraws at midnight even if the refresh then fails.
    private var dayChanges = 0

    public init(defaults: UserDefaults = .standard, cache: SnapshotCache? = nil, fetch: @escaping Fetch) {
        self.fetch = fetch
        self.defaults = defaults
        self.cache = cache
        snapshot = cache?.load()
        let savedGoal = defaults.integer(forKey: Keys.goal)
        goal = savedGoal > 0 ? savedGoal : 1000
        metric = defaults.string(forKey: Keys.metric).flatMap(PRMetric.init(rawValue:)) ?? .opened
        let savedMinutes = defaults.integer(forKey: Keys.refreshMinutes)
        refreshMinutes = savedMinutes > 0 ? savedMinutes : 15
    }

    public var count: Int? { currentSnapshot()?.count(for: metric) }

    /// The last good numbers, as long as they're for the month containing `now`. That is the month on the
    /// user's calendar as well as the window's own instants, which stop agreeing when the time zone changes.
    public func currentSnapshot(at now: Date = Date(), calendar: Calendar = .current) -> MonthSnapshot? {
        _ = dayChanges
        guard let snapshot, snapshot.window.contains(now) else { return nil }
        let windowMonth = snapshot.window.calendar.dateComponents([.year, .month], from: snapshot.window.start)
        let localMonth = calendar.dateComponents([.year, .month], from: now)
        return windowMonth.year == localMonth.year && windowMonth.month == localMonth.month ? snapshot : nil
    }

    public func pace(at now: Date = Date()) -> Pace? {
        guard let snapshot = currentSnapshot(at: now) else { return nil }
        return Pace(goal: goal, count: snapshot.count(for: metric), window: snapshot.window, at: now)
    }

    /// The popover header: the month of the current numbers, named in the zone they were counted in, or
    /// this month on the user's calendar while they're missing.
    public func monthTitle(at now: Date = Date(), calendar: Calendar = .current) -> String {
        let window = currentSnapshot(at: now, calendar: calendar)?.window
        return Self.monthName(of: window?.start ?? now, in: window?.calendar ?? calendar, year: true)
    }

    /// Where an ended month last stood, for when this month's numbers haven't arrived yet.
    public func lastMonthSummary(at now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard currentSnapshot(at: now, calendar: calendar) == nil, let snapshot else { return nil }
        let month = Self.monthName(of: snapshot.window.start, in: snapshot.window.calendar, year: false)
        let asOf = snapshot.fetchedAt.formatted(.dateTime.month(.abbreviated).day())
        return "Last count for \(month): \(snapshot.count(for: metric).formatted()) \(metric.noun), as of \(asOf)."
    }

    /// A month named on `calendar`, which a bare `formatted` would instead read in the system's zone.
    private static func monthName(of date: Date, in calendar: Calendar, year: Bool) -> String {
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(year ? style.month(.wide).year() : style.month(.wide))
    }

    /// When the numbers were fetched. Restored numbers can be days old, so the date appears once it isn't today.
    public func updatedText(at now: Date = Date()) -> String? {
        _ = dayChanges
        guard let snapshot else { return nil }
        // Both the day and the clock time are the user's own, wherever the numbers were counted.
        let fetchedToday = Calendar.current.isDate(snapshot.fetchedAt, inSameDayAs: now)
        let time = fetchedToday
            ? snapshot.fetchedAt.formatted(date: .omitted, time: .shortened)
            : snapshot.fetchedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "Updated \(time)"
    }

    /// Today's count, shown beside the menu bar ring.
    public func menuBarTitle(at now: Date = Date()) -> String {
        currentSnapshot(at: now).map { $0.todayCount(for: metric, at: now).formatted() } ?? "–"
    }

    /// Whether today's count has passed the daily quota, which turns the menu bar number green.
    public func menuBarBeatsPace(at now: Date = Date()) -> Bool {
        guard let snapshot = currentSnapshot(at: now), let pace = pace(at: now) else { return false }
        return pace.beatsDailyQuota(today: snapshot.todayCount(for: metric, at: now))
    }

    /// What VoiceOver reads for the menu bar item, since the image carries the numbers visually.
    public var menuBarAccessibilityLabel: String {
        let now = Date()
        guard let pace = pace(at: now) else { return "PR Tally, loading" }
        let today = "\(menuBarTitle(at: now)) today\(menuBarBeatsPace(at: now) ? ", beating the daily pace" : "")"
        return "\(today). \(pace.count.formatted()) of \(pace.goal.formatted()) \(metric.noun). \(pace.statusText)"
    }

    /// A failed refresh keeps the last good numbers on screen and reports the error next to them.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let dayChangesAtStart = dayChanges
        do {
            let fetched = try await fetch()
            snapshot = fetched
            errorMessage = nil
            cache?.save(fetched)
        } catch {
            errorMessage = error.localizedDescription
        }
        isRefreshing = false
        // A fetch that spanned midnight may have come back with the month that just ended.
        if dayChanges != dayChangesAtStart { await refresh() }
    }

    /// Today's numbers and possibly the month just changed, whether or not GitHub can be reached.
    func calendarDayChanged() async {
        // Foundation caches the system zone, which `Calendar.current` and the formatters would otherwise keep reading.
        NSTimeZone.resetSystemTimeZone()
        dayChanges += 1
        await refresh()
    }

    /// Refreshes when opened, unless the numbers are under a minute old.
    public func refreshIfStale(now: Date = Date()) async {
        if let fetchedAt = snapshot?.fetchedAt, now.timeIntervalSince(fetchedAt) < 60 { return }
        await refresh()
    }

    /// Begins refreshing on a schedule, after the Mac wakes, and when the day or time zone changes. Safe to call more than once.
    public func start() {
        if schedule == nil { startSchedule() }
        guard !watchingSystem else { return }
        watchingSystem = true
        Task { [weak self] in
            let wakes = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification)
            for await _ in wakes.map({ _ in () }) {
                try? await Task.sleep(for: .seconds(5))
                await self?.refresh()
            }
        }
        Task { [weak self] in
            // Posted at midnight, or on wake if the Mac slept through it.
            let days = NotificationCenter.default.notifications(named: .NSCalendarDayChanged)
            for await _ in days.map({ _ in () }) {
                await self?.calendarDayChanged()
            }
        }
        Task { [weak self] in
            // A new zone can put today in a different month, with no midnight to say so.
            let zones = NotificationCenter.default.notifications(named: .NSSystemTimeZoneDidChange)
            for await _ in zones.map({ _ in () }) {
                await self?.calendarDayChanged()
            }
        }
    }

    private func startSchedule() {
        schedule?.cancel()
        schedule = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.refresh()
                // Retry failures soon; the network is often just coming back.
                let delay: Duration = self.errorMessage == nil ? .seconds(self.refreshMinutes * 60) : .seconds(60)
                try? await Task.sleep(for: delay)
            }
        }
    }
}
