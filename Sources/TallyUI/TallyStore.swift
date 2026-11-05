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

    /// The last good numbers, as long as they're for the month containing `now`.
    public func currentSnapshot(at now: Date = Date()) -> MonthSnapshot? {
        _ = dayChanges
        return snapshot.flatMap { $0.window.contains(now) ? $0 : nil }
    }

    public func pace(at now: Date = Date()) -> Pace? {
        guard let snapshot = currentSnapshot(at: now) else { return nil }
        return Pace(goal: goal, count: snapshot.count(for: metric), window: snapshot.window, at: now)
    }

    /// Where an ended month last stood, for when this month's numbers haven't arrived yet.
    public func lastMonthSummary(at now: Date = Date()) -> String? {
        guard currentSnapshot(at: now) == nil, let snapshot else { return nil }
        let month = snapshot.window.start.formatted(.dateTime.month(.wide))
        let asOf = snapshot.fetchedAt.formatted(.dateTime.month(.abbreviated).day())
        return "Last count for \(month): \(snapshot.count(for: metric).formatted()) \(metric.noun), as of \(asOf)."
    }

    /// When the numbers were fetched. Restored numbers can be days old, so the date appears once it isn't today.
    public func updatedText(at now: Date = Date()) -> String? {
        _ = dayChanges
        guard let snapshot else { return nil }
        let fetchedToday = snapshot.window.calendar.isDate(snapshot.fetchedAt, inSameDayAs: now)
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
        dayChanges += 1
        await refresh()
    }

    /// Refreshes when opened, unless the numbers are under a minute old.
    public func refreshIfStale(now: Date = Date()) async {
        if let fetchedAt = snapshot?.fetchedAt, now.timeIntervalSince(fetchedAt) < 60 { return }
        await refresh()
    }

    /// Begins refreshing on a schedule, after the Mac wakes, and when the day changes. Safe to call more than once.
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
