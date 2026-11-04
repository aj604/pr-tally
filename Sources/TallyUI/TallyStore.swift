import AppKit
import Observation
import TallyCore

/// Holds the latest numbers and keeps them fresh.
@MainActor
@Observable
public final class TallyStore {
    public typealias Fetch = @Sendable () async throws -> MonthSnapshot

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
    private var schedule: Task<Void, Never>?
    private var watchingWakes = false

    public init(defaults: UserDefaults = .standard, fetch: @escaping Fetch) {
        self.fetch = fetch
        self.defaults = defaults
        let savedGoal = defaults.integer(forKey: Keys.goal)
        goal = savedGoal > 0 ? savedGoal : 1000
        metric = defaults.string(forKey: Keys.metric).flatMap(PRMetric.init(rawValue:)) ?? .opened
        let savedMinutes = defaults.integer(forKey: Keys.refreshMinutes)
        refreshMinutes = savedMinutes > 0 ? savedMinutes : 15
    }

    public var count: Int? { snapshot?.count(for: metric) }

    public func pace(at now: Date = Date()) -> Pace? {
        guard let snapshot, let count else { return nil }
        return Pace(goal: goal, count: count, window: snapshot.window, at: now)
    }

    /// Text shown beside the menu bar ring.
    public var menuBarTitle: String {
        count.map { $0.formatted() } ?? "–"
    }

    /// What VoiceOver reads for the menu bar item, since the ring carries the goal visually.
    public var menuBarAccessibilityLabel: String {
        guard let pace = pace() else { return "PR Tally, loading" }
        return "\(pace.count.formatted()) of \(pace.goal.formatted()) \(metric.noun). \(pace.statusText)"
    }

    /// A failed refresh keeps the last good numbers on screen and reports the error next to them.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await fetch()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refreshes when opened, unless the numbers are under a minute old.
    public func refreshIfStale(now: Date = Date()) async {
        if let fetchedAt = snapshot?.fetchedAt, now.timeIntervalSince(fetchedAt) < 60 { return }
        await refresh()
    }

    /// Begins refreshing on a schedule and after the Mac wakes. Safe to call more than once.
    public func start() {
        if schedule == nil { startSchedule() }
        guard !watchingWakes else { return }
        watchingWakes = true
        Task { [weak self] in
            let wakes = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification)
            for await _ in wakes.map({ _ in () }) {
                try? await Task.sleep(for: .seconds(5))
                await self?.refresh()
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
