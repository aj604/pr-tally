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
    public var goal = 1000
    public var metric: PRMetric = .opened
    public var refreshInterval: Duration = .seconds(15 * 60)

    private let fetch: Fetch
    private var started = false

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public var count: Int? { snapshot?.count(for: metric) }

    public func pace(at now: Date = Date()) -> Pace? {
        guard let snapshot, let count else { return nil }
        return Pace(goal: goal, count: count, window: snapshot.window, at: now)
    }

    /// Text shown in the menu bar, such as `74/1k`.
    public var menuBarTitle: String {
        "\(count.map(String.init) ?? "–")/\(Self.compact(goal))"
    }

    static func compact(_ goal: Int) -> String {
        goal >= 1000 && goal % 100 == 0
            ? (Double(goal) / 1000).formatted(.number.precision(.fractionLength(0...1))) + "k"
            : String(goal)
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
        guard !started else { return }
        started = true
        Task { [weak self] in
            while let self {
                await self.refresh()
                // Retry failures soon; the network is often just coming back.
                let delay = self.errorMessage == nil ? self.refreshInterval : .seconds(60)
                try? await Task.sleep(for: delay)
            }
        }
        Task { [weak self] in
            let wakes = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification)
            for await _ in wakes.map({ _ in () }) {
                try? await Task.sleep(for: .seconds(5))
                await self?.refresh()
            }
        }
    }
}
