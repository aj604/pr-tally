import AppKit
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
    /// repository picked from the top repos or a part of the merge funnel, and otherwise on what the menu bar number
    /// counts unless today has nothing yet.
    static func opening(for focus: PullRequestFocus, in snapshot: MonthSnapshot, metric: PRMetric, at now: Date) -> Self {
        if let day = focus.day { return day == snapshot.window.dayIndex(of: now) ? .today : .day(day) }
        if focus.repository != nil || focus.funnel != nil { return .month }
        return snapshot.todayCount(for: metric, at: now) > 0 ? .today : .month
    }
}

/// What the summary asked the pull request list to narrow to: a day from the charts, a repository from the top repos,
/// or a part of the merge funnel.
struct PullRequestFocus: Equatable {
    var day: Int?
    var repository: String?
    /// The count to list when it isn't the one the goal counts, as from the other metric's figure.
    var metric: PRMetric?
    var funnel: FunnelPart?

    /// The count the list shows: a funnel part's, the one asked for, or else `goal`, the one the goal counts.
    func listedMetric(goal: PRMetric) -> PRMetric {
        funnel?.metric ?? metric ?? goal
    }
}

/// A part of the merge funnel the list can narrow to, each with the metric that counts its PRs.
enum FunnelPart: Equatable {
    /// Opened this month and not merged yet.
    case notMerged
    /// Merged this month after being opened in an earlier month.
    case carriedIn

    var metric: PRMetric { self == .notMerged ? .opened : .merged }

    func pullRequests(in snapshot: MonthSnapshot) -> [PullRequest] {
        self == .notMerged ? snapshot.notMergedPullRequests : snapshot.carriedInPullRequests
    }
}

extension MonthSnapshot {
    /// The pull requests behind a count, newest first, by the date the metric counts them on, from one repository
    /// when `repository` is given. With `funnel`, only those the merge funnel counts in that part.
    func listedPullRequests(
        for metric: PRMetric, scope: PullRequestScope, repository: String? = nil, funnel: FunnelPart? = nil, at now: Date
    ) -> [PullRequest] {
        func counted(_ pr: PullRequest) -> Date? { metric == .opened ? pr.createdAt : pr.mergedAt }
        let today = window.dayIndex(of: now)
        let part = funnel.map { Set($0.pullRequests(in: self).map(\.id)) }
        return pullRequests(for: metric)
            .compactMap { pr in counted(pr).map { (pr, $0) } }
            .filter { pr, date in
                guard window.contains(date), repository.map({ pr.repository.nameWithOwner == $0 }) ?? true,
                    part?.contains(pr.id) ?? true
                else { return false }
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

    /// A pull request's time in the list, with its date when the list spans the month, in the zone the month was
    /// counted in, so it agrees with the day the PR is counted on.
    func rowTime(_ date: Date, withDay: Bool) -> String {
        var style = withDay
            ? Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
            : Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// The month's short name, in the zone the month was counted in.
    var monthTitle: String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated)
        style.timeZone = calendar.timeZone
        return start.formatted(style)
    }
}

/// The pull requests that make up the count, each opening on GitHub when clicked.
struct PullRequestList: View {
    let snapshot: MonthSnapshot
    let metric: PRMetric
    let now: Date
    private let copyLinkPasteboard: NSPasteboard
    @State private var scope: PullRequestScope
    @State private var repository: String?
    @State private var funnel: FunnelPart?
    @State private var searchText = ""

    /// `metric` is the one the goal counts; the focus can ask for the other.
    init(
        snapshot: MonthSnapshot, metric: PRMetric, now: Date, focus: PullRequestFocus = .init(),
        copyLinkPasteboard: NSPasteboard = .general
    ) {
        let metric = focus.listedMetric(goal: metric)
        self.snapshot = snapshot
        self.metric = metric
        self.now = now
        self.copyLinkPasteboard = copyLinkPasteboard
        _scope = State(initialValue: .opening(for: focus, in: snapshot, metric: metric, at: now))
        _repository = State(initialValue: focus.repository)
        _funnel = State(initialValue: focus.funnel)
    }

    var body: some View {
        let available = snapshot.listedPullRequests(for: metric, scope: scope, funnel: funnel, at: now)
        let repositories = PullRequestWorkspaceRepositories(available, selected: repository)
        let scoped = snapshot.listedPullRequests(
            for: metric, scope: scope, repository: repository, funnel: funnel, at: now
        )
        let search = PullRequestWorkspaceSearch(searchText)
        let pullRequests = search.results(in: scoped)
        VStack(alignment: .leading, spacing: 10) {
            // A picked day selects neither segment; its filter below says what is showing.
            Picker("Show", selection: $scope) {
                ForEach(PullRequestScope.pickable, id: \.self) { Text($0 == .today ? "Today" : "This month").tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            PullRequestWorkspaceRepositoryPicker(repositories: repositories, selection: $repository)
            filters
            HStack(spacing: 6) {
                TextField("Search title or repository", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search pull requests")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            HStack {
                Text(search.isActive
                     ? "\(pullRequests.count.formatted()) of \(scoped.count.formatted()) \(metric.noun)"
                     : "\(pullRequests.count.formatted()) \(metric.noun)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                PullRequestWorkspaceCopyLinksButton(pullRequests: pullRequests, pasteboard: copyLinkPasteboard)
            }
            if pullRequests.isEmpty {
                Text(search.isActive ? "No matching PRs in this list. Try another title or repository, or clear the search." : emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
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
        if day != nil || repository != nil || funnel != nil {
            HStack(spacing: 6) {
                if let day {
                    FilterChip(title: snapshot.window.dayTitle(day), help: "Show the whole month") { scope = .month }
                }
                if let repository {
                    FilterChip(title: repository, help: "Show every repository") { self.repository = nil }
                }
                switch funnel {
                case .notMerged:
                    FilterChip(title: "Not merged", help: "Show merged PRs too") { funnel = nil }
                case .carriedIn:
                    FilterChip(title: "Opened before \(snapshot.window.monthTitle)", help: "Show PRs opened this month too") {
                        funnel = nil
                    }
                case nil:
                    EmptyView()
                }
            }
        }
    }

    private var emptyText: String {
        let prs = repository.map { "\($0) PRs" } ?? "PRs"
        if funnel == .notMerged {
            return switch scope {
            case .today: "No unmerged \(prs) opened today."
            case .month: "No unmerged \(prs) opened this month."
            case .day(let day): "No unmerged \(prs) opened on \(snapshot.window.dayTitle(day))."
            }
        }
        if funnel == .carriedIn {
            return switch scope {
            case .today: "No older \(prs) merged today."
            case .month: "No older \(prs) merged this month."
            case .day(let day): "No older \(prs) merged on \(snapshot.window.dayTitle(day))."
            }
        }
        return switch scope {
        case .today: "No \(prs) \(metricVerb) today yet."
        case .month: "No \(prs) \(metricVerb) this month."
        case .day(let day): "No \(prs) \(metricVerb) on \(snapshot.window.dayTitle(day))."
        }
    }

    private var metricVerb: String { metric == .opened ? "opened" : "merged" }

    private func row(_ pr: PullRequest) -> some View {
        let date = (metric == .opened ? pr.createdAt : pr.mergedAt) ?? pr.createdAt
        return HStack(spacing: 6) {
            Link(destination: pr.url) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text(pr.repository.nameWithOwner).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 4)
                        Text(snapshot.window.rowTime(date, withDay: scope == .month)).monospacedDigit()
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
            PullRequestWorkspaceCopyLinkButton(pullRequest: pr, pasteboard: copyLinkPasteboard)
                .frame(width: 24, height: 24)
        }
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
