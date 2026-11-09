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
    /// Stops automatic fetches until resumed, including after relaunch. Manual refresh remains available.
    public var automaticRefreshPaused: Bool {
        didSet {
            defaults.set(automaticRefreshPaused, forKey: Keys.automaticRefreshPaused)
            refreshResumeTask?.cancel()
            refreshResumeTask = nil
            automaticRefreshResumeAt = nil
            defaults.set(nil, forKey: Keys.automaticRefreshResumeAt)
            guard automaticRefreshPaused != oldValue else { return }
            if automaticRefreshPaused {
                schedule?.cancel()
                schedule = nil
                nextTryAt = nil
            } else if started {
                startSchedule()
            }
        }
    }
    /// A timed pause's deadline. Nil keeps the existing pause-until-resumed behavior.
    public private(set) var automaticRefreshResumeAt: Date?
    /// The number shown beside the monthly progress ring. Today's count remains the default.
    public var menuBarDisplay: WorkflowMenuBarDisplay {
        didSet { defaults.set(menuBarDisplay.rawValue, forKey: Keys.menuBarDisplay) }
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
        static let menuBarDisplay = "workflowMenuBarDisplay"
        static let automaticRefreshPaused = "workflowAutomaticRefreshPaused"
        static let automaticRefreshResumeAt = "workflowAutomaticRefreshResumeAt"
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
    /// Refreshes that have failed in a row, and the latest failure, which together set how long the schedule
    /// waits. See `TallyStoreRetry`. Waiting for the network is neither, since its return triggers a refresh.
    private var failedRefreshes = 0
    private(set) var lastFailure: Error?
    /// When the schedule's current sleep ends, so a failure can say when the next try is. See `retryText(at:)`.
    private(set) var nextTryAt: Date?
    /// Whether the schedule is asleep waiting out a failure, which a success from anywhere else makes pointless.
    @ObservationIgnored private var sleepingOnFailure = false
    /// How long failures must last before the menu bar fades, shortened in tests.
    @ObservationIgnored var staleGrace: TimeInterval = 120
    /// Read for the time of a failed or waiting refresh, so tests can let minutes of retries pass.
    @ObservationIgnored var clock: () -> Date = Date.init
    /// How long the schedule waits to retry a failure, shortened in tests.
    @ObservationIgnored var retryDelay: Duration = .seconds(60)
    /// The schedule, waiting for a refresh it found already under way. See `refreshSettled()`.
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var schedule: Task<Void, Never>?
    private var refreshResumeTask: Task<Void, Never>?
    private var started = false
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
        let savedPause = defaults.object(forKey: Keys.automaticRefreshPaused) as? Bool ?? false
        let deadline = savedPause ? defaults.object(forKey: Keys.automaticRefreshResumeAt) as? Date : nil
        let pauseExpired = deadline.map { $0 <= Date() } ?? false
        automaticRefreshPaused = savedPause && !pauseExpired
        automaticRefreshResumeAt = pauseExpired ? nil : deadline
        if pauseExpired { defaults.set(false, forKey: Keys.automaticRefreshPaused) }
        if deadline == nil || pauseExpired { defaults.set(nil, forKey: Keys.automaticRefreshResumeAt) }
        menuBarDisplay = defaults.string(forKey: Keys.menuBarDisplay)
            .flatMap(WorkflowMenuBarDisplay.init(rawValue:)) ?? .today
    }

    public var count: Int? { currentSnapshot()?.count(for: metric) }

    /// Pauses automatic work until an absolute deadline, preserving it across relaunch.
    public func pauseAutomaticRefresh(until deadline: Date) {
        automaticRefreshPaused = true
        automaticRefreshResumeAt = deadline
        defaults.set(deadline, forKey: Keys.automaticRefreshResumeAt)
        resumeAutomaticRefreshIfDue(at: clock())
        if started { scheduleRefreshResume() }
    }

    /// Also checked on wake and automatic events: a sleeping Mac cannot run the deadline task on time.
    func resumeAutomaticRefreshIfDue(at now: Date) {
        guard automaticRefreshPaused, let deadline = automaticRefreshResumeAt, now >= deadline else { return }
        automaticRefreshPaused = false
    }

    private func scheduleRefreshResume() {
        refreshResumeTask?.cancel()
        guard let deadline = automaticRefreshResumeAt else { return }
        let delay = max(0, deadline.timeIntervalSince(clock()))
        refreshResumeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay), clock: .continuous) }
            catch { return }
            guard let self else { return }
            self.resumeAutomaticRefreshIfDue(at: self.clock())
            // If the system clock moved back, wait for the wall-clock deadline again.
            if self.automaticRefreshPaused { self.scheduleRefreshResume() }
        }
    }

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
        let updated = fetchedTime(at: now).map { "Updated \($0)" }
        guard automaticRefreshPaused else {
            guard let retry = retryText(at: now) else { return updated }
            return updated.map { "\($0) · \(retry)" } ?? retry
        }
        return updated.map { "\($0) · Paused" } ?? "Automatic refresh paused"
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

    /// Today's count or monthly count/goal, as chosen in Settings, beside the menu bar ring.
    public func menuBarTitle(at now: Date = Date()) -> String {
        guard let snapshot = currentSnapshot(at: now) else { return "–" }
        switch menuBarDisplay {
        case .today: return snapshot.todayCount(for: metric, at: now).formatted()
        case .monthProgress: return "\(snapshot.count(for: metric).formatted())/\(goal.formatted())"
        }
    }

    /// Monthly progress celebrates reaching the goal; today's count keeps its daily quota highlight.
    public func menuBarNumberIsGreen(at now: Date = Date()) -> Bool {
        switch menuBarDisplay {
        case .today: return menuBarBeatsPace(at: now)
        case .monthProgress: return pace(at: now)?.status == .goalHit
        }
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
        guard let stalledAt, let stalledSince, stalledAt.timeIntervalSince(stalledSince) >= staleGrace else { return false }
        guard let fetchedAt = currentSnapshot()?.fetchedAt else { return true }
        return stalledAt.timeIntervalSince(fetchedAt) >= Double(refreshMinutes * 60) + staleGrace
    }

    /// What VoiceOver reads for the menu bar item, since the image carries the numbers visually.
    public var menuBarAccessibilityLabel: String {
        let now = Date()
        if automaticRefreshPaused {
            let numbers = pace(at: now).map { "\($0.count.formatted()) of \($0.goal.formatted()) \(metric.noun). " } ?? ""
            let updated = fetchedTime(at: now).map { "Last updated \($0). " } ?? ""
            let resume = automaticRefreshResumeAt.map {
                "Resumes automatically \($0.formatted(date: .abbreviated, time: .shortened)). "
            } ?? ""
            return "PR Tally, automatic refresh paused. \(resume)\(numbers)\(updated)Refresh now is available in the popover."
        }
        guard let pace = pace(at: now) else {
            guard menuBarIsStale else { return "PR Tally, loading" }
            return "PR Tally, not updating" + (fetchedTime(at: now).map { " since \($0)" } ?? "") + retrySuffix(at: now)
        }
        let todayCount = currentSnapshot(at: now)?.todayCount(for: metric, at: now) ?? 0
        let today = "\(todayCount.formatted()) today\(menuBarBeatsPace(at: now) ? ", beating the daily pace" : "")"
        let label = "\(today). \(pace.count.formatted()) of \(pace.goal.formatted()) \(metric.noun). \(pace.statusText)"
        guard menuBarIsStale, let time = fetchedTime(at: now) else { return label }
        return "\(label). Not updating since \(time)" + retrySuffix(at: now)
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
            failedRefreshes = 0
            lastFailure = nil
            // The wait was for a failure that is over, such as a rate limit lifted by a new token. Without this the
            // next automatic refresh could be an hour away.
            if sleepingOnFailure, schedule != nil { startSchedule() }
            cache?.save(fetched)
            announceGoal(from: previous, to: fetched)
        } catch {
            errorMessage = error.localizedDescription
            failedRefreshes += 1
            lastFailure = error
            stalled()
        }
        isRefreshing = false
        refreshWaiters.forEach { $0.resume() }
        refreshWaiters = []
        // A fetch that spanned midnight may have come back with the month that just ended, and one that failed
        // may have failed only because the network was still coming back.
        let failedBeforeNetworkReturned = errorMessage != nil && isOnline && networkReturns != networkReturnsAtStart
        if !automaticRefreshPaused, dayChanges != dayChangesAtStart || failedBeforeNetworkReturned { await refresh() }
    }

    /// Tells the user once when a goal is reached, rather than on every refresh that finds it reached. Both
    /// metrics keep their own goal, so each is watched whichever one the popover is showing. A goal raised after
    /// reaching it is a new one and is announced in turn.
    private func announceGoal(from previous: MonthSnapshot?, to fetched: MonthSnapshot) {
        let month = fetched.window.monthKey
        // Earlier months' goals are let go as this month's are recorded.
        var announcedGoals = (defaults.stringArray(forKey: Keys.goalAnnounced) ?? []).filter { $0.hasPrefix("\(month) ") }
        for metric in PRMetric.allCases {
            let goal = metric == self.metric ? goal : defaults.integer(forKey: Keys.goalForMetric(metric))
            let announced = "\(month) \(metric.rawValue) \(goal)"
            guard let milestone = Milestone.goalReached(from: previous, to: fetched, metric: metric, goal: goal, at: Date()),
                !announcedGoals.contains(announced)
            else { continue }
            announcedGoals.append(announced)
            if notifiesOnGoal { notify?(milestone) }
        }
        // Recorded even with notifications off, so turning them on later doesn't announce a crossing from days ago.
        defaults.set(announcedGoals, forKey: Keys.goalAnnounced)
    }

    /// Today's numbers and possibly the month just changed, whether or not GitHub can be reached.
    func calendarDayChanged() async {
        // Foundation caches the system zone, which `Calendar.current` and the formatters would otherwise keep reading.
        NSTimeZone.resetSystemTimeZone()
        dayChanges += 1
        resumeAutomaticRefreshIfDue(at: clock())
        guard !automaticRefreshPaused else { return }
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
        resumeAutomaticRefreshIfDue(at: clock())
        guard !automaticRefreshPaused, cameBack, missedRefresh || errorMessage != nil else { return }
        await refresh()
    }

    /// Says why the numbers aren't updating, without spending a fetch and its retries on learning it.
    private func waitForNetwork() {
        missedRefresh = true
        errorMessage = Self.offlineMessage
        // Reconnecting refreshes at once, so offline polling stays at the base delay however long the last failures ran.
        failedRefreshes = 0
        lastFailure = nil
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
        resumeAutomaticRefreshIfDue(at: now)
        guard !automaticRefreshPaused else { return }
        if let fetchedAt = snapshot?.fetchedAt, now.timeIntervalSince(fetchedAt) < 60 { return }
        guard isOnline else { return waitForNetwork() }
        await refresh()
    }

    /// Begins refreshing on a schedule, after the Mac wakes, when the network comes back, and when the day or
    /// time zone changes. Safe to call more than once.
    public func start() {
        start(observingSystem: true)
    }

    /// Tests drive wake, network and calendar events directly, without observing the machine's events.
    func start(observingSystem: Bool) {
        resumeAutomaticRefreshIfDue(at: clock())
        if !automaticRefreshPaused, schedule == nil { startSchedule() }
        guard !started else { return }
        started = true
        scheduleRefreshResume()
        guard observingSystem else { return }
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
        resumeAutomaticRefreshIfDue(at: clock())
        guard !automaticRefreshPaused else { return }
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

    /// A normal interval after success. After a failure, soon at first, since the network is often just coming
    /// back, then less often while it lasts; see `TallyStoreRetry`.
    func nextDelay() -> Duration {
        let interval = Duration.seconds(refreshMinutes * 60)
        guard errorMessage != nil else { return interval }
        return TallyStoreRetry.delay(
            afterFailures: failedRefreshes, error: lastFailure, base: retryDelay, interval: interval, now: clock())
    }

    private func startSchedule() {
        schedule?.cancel()
        sleepingOnFailure = false
        nextTryAt = nil
        schedule = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.refreshIfStale()
                await self.refreshSettled()
                await self.sleepUntilNextTry()
            }
        }
    }

    private func sleepUntilNextTry() async {
        let delay = nextDelay()
        nextTryAt = clock().addingTimeInterval(delay.timeInterval)
        await sleep(through: delay)
        if !Task.isCancelled { nextTryAt = nil }
    }

    private func sleep(through delay: Duration) async {
        guard errorMessage != nil else { return await sleep(delay) }
        sleepingOnFailure = true
        defer { if !Task.isCancelled { sleepingOnFailure = false } }
        // A long wait, such as a rate limit's, would otherwise leave the menu bar unfaded until it ended: it fades
        // only when a failure is recorded after the grace period. So the wait is split to record one then.
        if let stalledSince {
            let untilStale = Duration.seconds(max(0, stalledSince.addingTimeInterval(staleGrace).timeIntervalSince(clock())))
            if untilStale > .zero, untilStale < delay {
                await sleep(untilStale)
                guard !Task.isCancelled else { return }
                stalled()
                return await sleep(delay - untilStale)
            }
        }
        await sleep(delay)
    }

    private func sleep(_ duration: Duration) async {
        try? await Task.sleep(for: duration, clock: .suspending)
    }
}
