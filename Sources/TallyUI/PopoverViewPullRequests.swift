import AppKit
import SwiftUI
import TallyCore

/// How far back the pull request list reaches.
enum PullRequestScope: Hashable {
    case today, month
    /// One zero-based day of the month, picked from the charts or stepped to in the list.
    case day(Int)

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
enum FunnelPart: Hashable {
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

    /// A pull request's time in the list, in the zone the month was counted in, so it agrees with the day the PR is
    /// counted on. The day itself is in the segment or the row's section header, unless the whole month lists without
    /// sections, when `withDay` puts it on the row.
    func rowTime(_ date: Date, withDay: Bool = false) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        guard withDay, let day = dayIndex(of: date) else { return date.formatted(style) }
        return "\(dayTitle(day)), \(date.formatted(style))"
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
    let now: Date
    private let copyLinkPasteboard: NSPasteboard
    /// The day the day segment shows, kept while the whole month is showing so picking the segment returns to it.
    @State private var day: Int
    @State private var metric: PRMetric
    @State private var wholeMonth: Bool
    @State private var repository: String?
    /// A status, review or merge-funnel part, picked from one menu.
    @State private var statusChoice: PullRequestWorkspaceStatusFilter.Choice?
    @State private var searchText = ""
    @State private var sort = PullRequestWorkspaceSort.newest

    /// `metric` is the one the goal counts; the focus can ask for the other.
    init(
        snapshot: MonthSnapshot, metric: PRMetric, now: Date, focus: PullRequestFocus = .init(),
        copyLinkPasteboard: NSPasteboard = .general
    ) {
        let metric = focus.listedMetric(goal: metric)
        self.snapshot = snapshot
        _metric = State(initialValue: metric)
        self.now = now
        self.copyLinkPasteboard = copyLinkPasteboard
        let scope = PullRequestScope.opening(for: focus, in: snapshot, metric: metric, at: now)
        _day = State(initialValue: PullRequestWorkspaceDayStepper.openingDay(for: scope, in: snapshot.window, at: now))
        _wholeMonth = State(initialValue: scope == .month)
        _repository = State(initialValue: focus.repository)
        _statusChoice = State(initialValue: focus.funnel.map { .funnel($0) })
    }

    /// Switching keeps the day, repository, status and search, and drops a funnel part the new metric can't match.
    private var metricSelection: Binding<PRMetric> {
        Binding(get: { metric }) { newValue in
            metric = newValue
            statusChoice = PullRequestWorkspaceMetric.choice(statusChoice, keptFor: newValue)
        }
    }

    private var funnel: FunnelPart? { statusChoice?.funnelPart }

    private var stepper: PullRequestWorkspaceDayStepper { .init(day: day, in: snapshot.window, at: now) }

    private var scope: PullRequestScope { wholeMonth ? .month : stepper.scope }

    var body: some View {
        let members = PullRequestWorkspaceStatusFilter.funnelMembers(for: metric, in: snapshot)
        let available = snapshot.listedPullRequests(for: metric, scope: scope, at: now)
        let inRepository = snapshot.listedPullRequests(for: metric, scope: scope, repository: repository, at: now)
        // Each picker counts what the other has left, so a choice never offers a count the list won't show.
        let repositories = PullRequestWorkspaceRepositories(
            PullRequestWorkspaceStatusFilter.apply(statusChoice, to: available, funnel: members), selected: repository
        )
        let statuses = PullRequestWorkspaceStatusFilter(inRepository, funnel: members, selected: statusChoice)
        let scoped = PullRequestWorkspaceStatusFilter.apply(statusChoice, to: inRepository, funnel: members)
        let search = PullRequestWorkspaceSearch(searchText)
        let pullRequests = sort.apply(to: search.results(in: scoped), at: now)
        let metrics = PullRequestWorkspaceMetric { other in
            other == metric ? scoped.count : PullRequestWorkspaceStatusFilter.apply(
                PullRequestWorkspaceMetric.choice(statusChoice, keptFor: other),
                to: snapshot.listedPullRequests(for: other, scope: scope, repository: repository, at: now),
                funnel: PullRequestWorkspaceStatusFilter.funnelMembers(for: other, in: snapshot)
            ).count
        }
        VStack(alignment: .leading, spacing: 10) {
            scopeBar(metrics)
            HStack(spacing: 6) {
                PullRequestWorkspaceRepositoryPicker(repositories: repositories, selection: $repository)
                if statuses.isOffered {
                    PullRequestWorkspaceStatusPicker(filter: statuses, selection: $statusChoice)
                        // Capped so the repository picker keeps room for a readable name; the menu lists full titles.
                        .frame(maxWidth: 128)
                }
            }
            // The count lives in the field's placeholder and the copy action at its end, so the controls take one
            // row fewer before the first PR.
            HStack(spacing: 6) {
                TextField(PullRequestWorkspaceSearch.prompt(count: scoped.count, metric: metric), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search pull requests")
                    .help("Search this list by title, repository, #123, owner/repository#123, or a PR URL")
                    .accessibilityHint("Search this list by title, repository, #123, owner/repository#123, or a PR URL")
                if let matches = search.matchText(pullRequests.count, of: scoped.count) {
                    Text(matches)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel(search.matchAccessibilityLabel(pullRequests.count, of: scoped.count, metric: metric) ?? matches)
                }
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
                if PullRequestWorkspaceSort.isOffered(sort, for: scoped, at: now) {
                    PullRequestWorkspaceSortPicker(selection: $sort)
                        .frame(width: 24, height: 24)
                }
                PullRequestWorkspaceCopyLinksButton(pullRequests: pullRequests, pasteboard: copyLinkPasteboard)
                    .frame(width: 24, height: 24)
            }
            if pullRequests.isEmpty {
                Text(search.isActive ? "No matching PRs in this list. Try another search, change the filters, or clear the search."
                     : statusChoice != nil && funnel == nil ? "No PRs with that status in this list. Choose another status or show all statuses." : emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                let groups = scope == .month && sort.groupsByDay
                    ? PullRequestWorkspaceDayGroups(pullRequests, metric: metric, in: snapshot.window, at: now).groups : nil
                // A short list sizes itself; a long one scrolls within the popover's height.
                ViewThatFits(in: .vertical) {
                    VStack(alignment: .leading, spacing: 0) { rows(pullRequests, groups: groups) }
                    ScrollView { LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) { rows(pullRequests, groups: groups) } }
                }
                .frame(maxHeight: 340)
            }
        }
    }

    /// The whole month reads as one section per day unless it is ranked slowest to merge; a single day is already named
    /// by its segment, so it lists plainly.
    @ViewBuilder private func rows(_ pullRequests: [PullRequest], groups: [PullRequestWorkspaceDayGroups.Group]?) -> some View {
        if let groups {
            ForEach(groups) { group in
                Section {
                    ForEach(group.pullRequests) { row($0) }
                } header: {
                    dayHeader(group)
                }
            }
        } else {
            ForEach(pullRequests) { row($0) }
        }
    }

    /// A day's section header opens that day in the day segment, so a busy day spotted in the month is one click from
    /// its own list and from stepping to its neighbours.
    private func dayHeader(_ group: PullRequestWorkspaceDayGroups.Group) -> some View {
        Button {
            day = group.day
            wholeMonth = false
        } label: {
            HStack(spacing: 4) {
                Text(group.title).fontWeight(.semibold)
                Spacer(minLength: 4)
                Text(group.countText).monospacedDigit()
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show only \(group.title)")
        .accessibilityLabel("\(group.title), \(group.countText)")
        .accessibilityHint("Shows only this day")
    }

    /// The day segment names the day it shows, and the arrows beside it step that day, so a day picked from the charts
    /// needs no filter of its own and its neighbours are a click away. The metric leads the row, so it reads as what
    /// the list holds: "Opened ‹ Today ›".
    private func scopeBar(_ metrics: PullRequestWorkspaceMetric) -> some View {
        let stepper = stepper
        return HStack(spacing: 2) {
            PullRequestWorkspaceMetricPicker(metrics: metrics, selection: metricSelection)
                .padding(.trailing, 4)
            dayArrow(to: stepper.previous, step: .previous)
            Picker("Show", selection: $wholeMonth) {
                Text(stepper.title).tag(false)
                Text("This month").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            dayArrow(to: stepper.next, step: .next)
        }
    }

    /// Stepping works on the day segment, so the arrows rest while the whole month is showing, and their shortcuts
    /// with them. The step is worked out from the day showing when pressed: a shortcut can run the action from an
    /// earlier render, whose target is the day it already stepped to.
    private func dayArrow(to target: PullRequestWorkspaceDayStepper.Day?, step: PullRequestWorkspaceDayStepper.Step) -> some View {
        Button {
            if let next = step.target(of: stepper) { day = next.day }
        } label: {
            Image(systemName: step.systemImage).frame(width: 18, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(step.key, modifiers: .command)
        .disabled(wholeMonth || target == nil)
        .help(step.help(to: target))
        .accessibilityLabel(step.label)
        .accessibilityValue(target?.title ?? "")
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
        let mergeTime = PullRequestWorkspaceMergeTime(pr)
        let openTime = PullRequestWorkspaceOpenTime(pr, at: now)
        // A merge or open time already says where the PR stands, so it takes the status label's place rather than
        // sitting beside it.
        let status = mergeTime == nil && openTime == nil ? PullRequestWorkspaceStatus.badge(for: pr, metric: metric) : nil
        let review = PullRequestWorkspaceReview.badge(for: pr, metric: metric)
        let checks = PullRequestWorkspaceChecks.badge(for: pr, metric: metric)
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
                        if let status {
                            Text(status.label).font(.caption2.weight(.medium)).foregroundStyle(status.tint)
                                .lineLimit(1).fixedSize()
                        }
                        if let mergeTime {
                            Text(mergeTime.label).font(.caption2.weight(.medium)).foregroundStyle(mergeTime.tint)
                                .lineLimit(1).fixedSize()
                                .accessibilityLabel(mergeTime.accessibilityLabel)
                        }
                        if let openTime {
                            Text(openTime.label).font(.caption2.weight(.medium)).foregroundStyle(openTime.tint)
                                .lineLimit(1).fixedSize()
                                .accessibilityLabel(openTime.accessibilityLabel)
                        }
                        if let review {
                            Text(review.label).font(.caption2.weight(.medium)).foregroundStyle(review.tint)
                                .lineLimit(1).fixedSize()
                        }
                        if let checks {
                            Text(checks.label).font(.caption2.weight(.medium)).foregroundStyle(checks.tint)
                                .lineLimit(1).fixedSize()
                        }
                        Text(snapshot.window.rowTime(date, withDay: scope == .month && !sort.groupsByDay)).monospacedDigit().lineLimit(1).fixedSize()
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
            .accessibilityLabel(
                [pr.title, pr.repository.nameWithOwner, status?.label, mergeTime?.accessibilityLabel, openTime?.accessibilityLabel, review?.label, checks?.label].compactMap { $0 }.joined(separator: ", ")
            )
            PullRequestWorkspaceCopyLinkButton(pullRequest: pr, pasteboard: copyLinkPasteboard)
                .frame(width: 24, height: 24)
        }
    }
}
