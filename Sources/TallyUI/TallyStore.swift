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
    /// The monthly goal for the selected metric. Each metric keeps its own target.
    public var goal: Int {
        didSet {
            if goal < 1 { goal = 1 }
            defaults.set(goal, forKey: Keys.goal)
            defaults.set(goal, forKey: Keys.goalForMetric(metric))
        }
    }
    public var metric: PRMetric {
        didSet {
            defaults.set(metric.rawValue, forKey: Keys.metric)
            guard metric != oldValue else { return }
            goal = defaults.integer(forKey: Keys.goalForMetric(metric))
        }
    }
    /// Whether reaching the goal sends a notification. On by default; the system asks permission the first time.
    public var notifiesOnGoal: Bool {
        didSet { defaults.set(notifiesOnGoal, forKey: Keys.notifiesOnGoal) }
    }
    public var refreshMinutes: Int {
        didSet {
            defaults.set(refreshMinutes, forKey: Keys.refreshMinutes)
            if schedule != nil { startSchedule() }
        }
    }

    /// What the popover shows. Kept here rather than in the view because `MenuBarExtra` keeps the view's own
    /// state alive while the popover is closed; see `popoverClosed()`.
    public enum Screen: Sendable { case summary, pullRequests, settings }

    public var screen = Screen.summary

    private enum Keys {
        static let goal = "goal"
        static func goalForMetric(_ metric: PRMetric) -> String { "workflowGoal.\(metric.rawValue)" }
        static let metric = "metric"
        static let refreshMinutes = "refreshMinutes"
        static let notifiesOnGoal = "notifiesOnGoal"
        /// The goals announced this month, each named by month, metric and number. See `announceGoal(from:to:)`.
        static let goalAnnounced = "goalAnnounced"
    }

    private let fetch: Fetch
    private let defaults: UserDefaults
    private let cache: SnapshotCache?
    private let notify: (@MainActor (Milestone) -> Void)?
    private let network: NetworkStatus
    /// Assumed until the system says otherwise, so a launch doesn't wait on it.
    private var isOnline = true
    /// Whether a refresh was due while offline, which the network coming back then makes up for.
    private var missedRefresh = false
    /// Counts the network coming back, so a fetch that failed while it did is tried again.
    private var networkReturns = 0
    /// When the latest refresh failed or waited for the network, until one succeeds. Set again on every try, so
    /// the menu bar redraws as each retry finds the numbers a little older.
    private var stalledAt: Date?
    /// When the refreshes since the last good one started failing or waiting for the network.
    private var stalledSince: Date?
    /// Read for the time of a failed or waiting refresh, so tests can let minutes of retries pass.
    @ObservationIgnored var clock: () -> Date = Date.init
    /// How long the schedule waits to retry a failure, shortened in tests.
    @ObservationIgnored var retryDelay: Duration = .seconds(60)
    /// The schedule, waiting for a refresh it found already under way. See `refreshSettled()`.
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var schedule: Task<Void, Never>?
    private var watchingSystem = false
    /// Read by everything that depends on today's date, so it redraws at midnight even if the refresh then fails.
    private var dayChanges = 0

    public init(
        defaults: UserDefaults = .standard, cache: SnapshotCache? = nil,
        notify: (@MainActor (Milestone) -> Void)? = nil, network: NetworkStatus = .system, fetch: @escaping Fetch
    ) {
        self.fetch = fetch
        self.defaults = defaults
        self.cache = cache
        self.notify = notify
        self.network = network
        snapshot = cache?.load()
        let savedGoal = defaults.integer(forKey: Keys.goal)
        let legacyGoal = savedGoal > 0 ? savedGoal : 1000
        // Seed both before either can be edited, so a first switch keeps the original shared target.
        for metric in PRMetric.allCases where defaults.integer(forKey: Keys.goalForMetric(metric)) < 1 {
            defaults.set(legacyGoal, forKey: Keys.goalForMetric(metric))
        }
        let savedMetric = defaults.string(forKey: Keys.metric).flatMap(PRMetric.init(rawValue:)) ?? .opened
        goal = defaults.integer(forKey: Keys.goalForMetric(savedMetric))
        metric = savedMetric
        notifiesOnGoal = defaults.object(forKey: Keys.notifiesOnGoal) as? Bool ?? true
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
        fetchedTime(at: now).map { "Updated \($0)" }
    }

    private func fetchedTime(at now: Date) -> String? {
        _ = dayChanges
        guard let snapshot else { return nil }
        // Both the day and the clock time are the user's own, wherever the numbers were counted.
        let fetchedToday = Calendar.current.isDate(snapshot.fetchedAt, inSameDayAs: now)
        return fetchedToday
            ? snapshot.fetchedAt.formatted(date: .omitted, time: .shortened)
            : snapshot.fetchedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
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

    /// Whether the menu bar has stopped updating, which fades it: refreshes have been failing, or waiting for the
    /// network, for two minutes, and the numbers, if there are any this month, are more than two minutes past
    /// when the schedule's next one was due. So the first try and the retry a minute later are left to put
    /// things right unseen, whether that try is the schedule's own or the one on waking hours later.
    ///
    /// With no numbers for this month, the "–" fades the same way, so a first launch that can't sign in, or a new
    /// month that can't be fetched, doesn't look like loading for good.
    public var menuBarIsStale: Bool {
        guard let stalledAt, let stalledSince, stalledAt.timeIntervalSince(stalledSince) >= 120 else { return false }
        guard let fetchedAt = currentSnapshot()?.fetchedAt else { return true }
        return stalledAt.timeIntervalSince(fetchedAt) >= Double(refreshMinutes * 60 + 120)
    }

    /// What VoiceOver reads for the menu bar item, since the image carries the numbers visually.
    public var menuBarAccessibilityLabel: String {
        let now = Date()
        guard let pace = pace(at: now) else {
            guard menuBarIsStale else { return "PR Tally, loading" }
            return "PR Tally, not updating" + (fetchedTime(at: now).map { " since \($0)" } ?? "")
        }
        let today = "\(menuBarTitle(at: now)) today\(menuBarBeatsPace(at: now) ? ", beating the daily pace" : "")"
        let label = "\(today). \(pace.count.formatted()) of \(pace.goal.formatted()) \(metric.noun). \(pace.statusText)"
        guard menuBarIsStale, let time = fetchedTime(at: now) else { return label }
        return "\(label). Not updating since \(time)"
    }

    /// A failed refresh keeps the last good numbers on screen and reports the error next to them.
    ///
    /// Always tries, offline or not, since this is also what the refresh button asks for.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        missedRefresh = false
        let dayChangesAtStart = dayChanges
        let networkReturnsAtStart = networkReturns
        do {
            // Runs apart from whoever asked: closing the popover cancels its `.task`, and changing the
            // interval cancels the schedule, but the numbers are still wanted either way.
            let fetched = try await Task { try await fetch() }.value
            let previous = snapshot
            snapshot = fetched
            errorMessage = nil
            stalledAt = nil
            stalledSince = nil
            cache?.save(fetched)
            announceGoal(from: previous, to: fetched)
        } catch {
            errorMessage = error.localizedDescription
            stalled()
        }
        isRefreshing = false
        refreshWaiters.forEach { $0.resume() }
        refreshWaiters = []
        // A fetch that spanned midnight may have come back with the month that just ended, and one that failed
        // may have failed only because the network was still coming back.
        let failedBeforeNetworkReturned = errorMessage != nil && isOnline && networkReturns != networkReturnsAtStart
        if dayChanges != dayChangesAtStart || failedBeforeNetworkReturned { await refresh() }
    }

    /// Tells the user once when the goal is reached, rather than on every refresh that finds it reached. A goal
    /// raised after reaching it, or reached in the other metric, is a new one and is announced in turn.
    private func announceGoal(from previous: MonthSnapshot?, to fetched: MonthSnapshot) {
        let month = fetched.window.monthKey
        let announced = "\(month) \(metric.rawValue) \(goal)"
        // Earlier months' goals are let go as this month's are recorded.
        let thisMonth = (defaults.stringArray(forKey: Keys.goalAnnounced) ?? []).filter { $0.hasPrefix("\(month) ") }
        guard let milestone = Milestone.goalReached(from: previous, to: fetched, metric: metric, goal: goal, at: Date()),
            !thisMonth.contains(announced)
        else { return }
        // Recorded even with notifications off, so turning them on later doesn't announce a crossing from days ago.
        defaults.set(thisMonth + [announced], forKey: Keys.goalAnnounced)
        if notifiesOnGoal { notify?(milestone) }
    }

    /// Today's numbers and possibly the month just changed, whether or not GitHub can be reached.
    func calendarDayChanged() async {
        // Foundation caches the system zone, which `Calendar.current` and the formatters would otherwise keep reading.
        NSTimeZone.resetSystemTimeZone()
        dayChanges += 1
        if isOnline {
            await refresh()
        } else {
            waitForNetwork()
        }
    }

    static let offlineMessage = "No network connection. The numbers will update when it's back."

    /// Coming back online makes up for a refresh that waited or failed, at once rather than on the next tick.
    func networkChanged(isOnline online: Bool) async {
        let cameBack = online && !isOnline
        isOnline = online
        if cameBack { networkReturns += 1 }
        guard cameBack, missedRefresh || errorMessage != nil else { return }
        await refresh()
    }

    /// Says why the numbers aren't updating, without spending a fetch and its retries on learning it.
    private func waitForNetwork() {
        missedRefresh = true
        errorMessage = Self.offlineMessage
        stalled()
    }

    private func stalled() {
        let now = clock()
        stalledAt = now
        if stalledSince == nil { stalledSince = now }
    }

    /// The next opening starts at the numbers, not wherever the last one ended: Settings or the PR list
    /// would otherwise be what you see the next time you glance at the menu bar.
    public func popoverClosed() {
        screen = .summary
    }

    /// Refreshes when nobody pressed the button: on opening, on the schedule, after a wake. Numbers under a
    /// minute old are left alone, so these don't stack up, and while offline it waits for the network.
    public func refreshIfStale(now: Date = Date()) async {
        if let fetchedAt = snapshot?.fetchedAt, now.timeIntervalSince(fetchedAt) < 60 { return }
        guard isOnline else { return waitForNetwork() }
        await refresh()
    }

    /// Begins refreshing on a schedule, after the Mac wakes, when the network comes back, and when the day or
    /// time zone changes. Safe to call more than once.
    public func start() {
        if schedule == nil { startSchedule() }
        guard !watchingSystem else { return }
        watchingSystem = true
        Task { [weak self, network] in
            for await online in network.changes() {
                await self?.networkChanged(isOnline: online)
            }
        }
        Task { [weak self] in
            let wakes = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification)
            for await _ in wakes.map({ _ in () }) {
                try? await Task.sleep(for: .seconds(5))
                self?.systemWoke()
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

    /// Once the network has had a few seconds after a wake, the schedule starts over: one refresh, and a retry a
    /// minute later if that fails. Its clock stops while the Mac sleeps, so it doesn't also fire as the lid opens.
    func systemWoke() {
        // Hours asleep aren't hours of failing, so a stall the menu bar wasn't showing yet starts over. One it was
        // showing stays shown rather than flickering back for two minutes.
        if !menuBarIsStale {
            stalledAt = nil
            stalledSince = nil
        }
        if schedule != nil { startSchedule() }
    }

    /// Waits out a refresh that was already under way, such as the day change's on waking, so the schedule picks
    /// its next delay from how that one went rather than from before it.
    private func refreshSettled() async {
        // Again after each finish, since a refresh can go straight into another.
        while isRefreshing {
            await withCheckedContinuation { refreshWaiters.append($0) }
        }
    }

    private func startSchedule() {
        schedule?.cancel()
        schedule = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.refreshIfStale()
                await self.refreshSettled()
                // Retry failures soon; the network is often just coming back.
                let delay: Duration = self.errorMessage == nil ? .seconds(self.refreshMinutes * 60) : self.retryDelay
                try? await Task.sleep(for: delay, clock: .suspending)
            }
        }
    }
}
