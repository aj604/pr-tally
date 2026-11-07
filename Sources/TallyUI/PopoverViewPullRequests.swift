import SwiftUI
import TallyCore

/// How far back the pull request list reaches.
enum PullRequestScope: Hashable {
    case today, month
    /// One zero-based day of the month, picked from the charts.
    case day(Int)

    /// The scopes the picker offers. A picked day shows as a filter beside it instead.
    static let pickable: [PullRequestScope] = [.today, .month]

    /// Where the list opens: on a day picked from the charts (as Today when it is today), on the whole month for a
    /// repository picked from the top repos, and otherwise on what the menu bar number counts unless today has nothing yet.
    static func opening(for focus: PullRequestFocus, in snapshot: MonthSnapshot, metric: PRMetric, at now: Date) -> Self {
        if let day = focus.day { return day == snapshot.window.dayIndex(of: now) ? .today : .day(day) }
        if focus.repository != nil { return .month }
        return snapshot.todayCount(for: metric, at: now) > 0 ? .today : .month
    }
}

/// What the summary asked the pull request list to narrow to: a day from the charts or a repository from the top repos.
struct PullRequestFocus: Equatable {
    var day: Int?
    var repository: String?
}

extension MonthSnapshot {
    /// The pull requests behind a count, newest first, by the date the metric counts them on, from one repository
    /// when `repository` is given.
    func listedPullRequests(
        for metric: PRMetric, scope: PullRequestScope, repository: String? = nil, at now: Date
    ) -> [PullRequest] {
        func counted(_ pr: PullRequest) -> Date? { metric == .opened ? pr.createdAt : pr.mergedAt }
        let today = window.dayIndex(of: now)
        return pullRequests(for: metric)
            .compactMap { pr in counted(pr).map { (pr, $0) } }
            .filter { pr, date in
                guard window.contains(date), repository.map({ pr.repository.nameWithOwner == $0 }) ?? true else {
                    return false
                }
                switch scope {
                case .month: return true
                case .today: return window.dayIndex(of: date) == today
                case .day(let day): return window.dayIndex(of: date) == day
                }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

extension MonthWindow {
    /// A zero-based day of the month as a short date, in the zone the month was counted in.
    func dayTitle(_ day: Int) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        return calendar.date(byAdding: .day, value: day, to: start)!.formatted(style)
    }
}

/// The pull requests that make up the count, each opening on GitHub when clicked.
struct PullRequestList: View {
    let snapshot: MonthSnapshot
    let metric: PRMetric
    let now: Date
    @State private var scope: PullRequestScope
    @State private var repository: String?

    init(snapshot: MonthSnapshot, metric: PRMetric, now: Date, focus: PullRequestFocus = .init()) {
        self.snapshot = snapshot
        self.metric = metric
        self.now = now
        _scope = State(initialValue: .opening(for: focus, in: snapshot, metric: metric, at: now))
        _repository = State(initialValue: focus.repository)
    }

    var body: some View {
        let pullRequests = snapshot.listedPullRequests(for: metric, scope: scope, repository: repository, at: now)
        VStack(alignment: .leading, spacing: 10) {
            // A picked day selects neither segment; its filter below says what is showing.
            Picker("Show", selection: $scope) {
                ForEach(PullRequestScope.pickable, id: \.self) { Text($0 == .today ? "Today" : "This month").tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            filters
            if pullRequests.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Text("\(pullRequests.count.formatted()) \(metric.noun)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // A short list sizes itself; a long one scrolls within the popover's height.
                ViewThatFits(in: .vertical) {
                    VStack(alignment: .leading, spacing: 0) { ForEach(pullRequests) { row($0) } }
                    ScrollView { rows(pullRequests) }
                }
                .frame(maxHeight: 340)
            }
        }
    }

    private func rows(_ pullRequests: [PullRequest]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(pullRequests) { row($0) }
        }
    }

    @ViewBuilder private var filters: some View {
        let day: Int? = if case .day(let day) = scope { day } else { nil }
        if day != nil || repository != nil {
            HStack(spacing: 6) {
                if let day {
                    FilterChip(title: snapshot.window.dayTitle(day), help: "Show the whole month") { scope = .month }
                }
                if let repository {
                    FilterChip(title: repository, help: "Show every repository") { self.repository = nil }
                }
            }
        }
    }

    private var emptyText: String {
        let prs = repository.map { "\($0) PRs" } ?? "PRs"
        return switch scope {
        case .today: "No \(prs) \(metricVerb) today yet."
        case .month: "No \(prs) \(metricVerb) this month."
        case .day(let day): "No \(prs) \(metricVerb) on \(snapshot.window.dayTitle(day))."
        }
    }

    private var metricVerb: String { metric == .opened ? "opened" : "merged" }

    private func row(_ pr: PullRequest) -> some View {
        let date = (metric == .opened ? pr.createdAt : pr.mergedAt) ?? pr.createdAt
        return Link(destination: pr.url) {
            VStack(alignment: .leading, spacing: 1) {
                Text(pr.title)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text(pr.repository.nameWithOwner).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 4)
                    Text(
                        scope != .month
                            ? date.formatted(date: .omitted, time: .shortened)
                            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                    )
                    .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pr.title)
        .accessibilityLabel("\(pr.title), \(pr.repository.nameWithOwner)")
    }
}

/// A filter on the list, removed by clicking it.
private struct FilterChip: View {
    let title: String
    let help: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quaternary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(title) filter")
        .accessibilityHint(help)
    }
}
