import SwiftUI
import TallyCore

/// How far back the pull request list reaches.
enum PullRequestScope: String, CaseIterable, Identifiable {
    case today, month
    var id: String { rawValue }
    var title: String { self == .today ? "Today" : "This month" }
}

extension MonthSnapshot {
    /// The pull requests behind a count, newest first, by the date the metric counts them on.
    func listedPullRequests(for metric: PRMetric, scope: PullRequestScope, at now: Date) -> [PullRequest] {
        func counted(_ pr: PullRequest) -> Date? { metric == .opened ? pr.createdAt : pr.mergedAt }
        let today = window.dayIndex(of: now)
        return pullRequests(for: metric)
            .compactMap { pr in counted(pr).map { (pr, $0) } }
            .filter { _, date in
                guard window.contains(date) else { return false }
                return scope == .month || window.dayIndex(of: date) == today
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

/// The pull requests that make up the count, each opening on GitHub when clicked.
struct PullRequestList: View {
    let snapshot: MonthSnapshot
    let metric: PRMetric
    let now: Date
    @State private var scope: PullRequestScope

    init(snapshot: MonthSnapshot, metric: PRMetric, now: Date) {
        self.snapshot = snapshot
        self.metric = metric
        self.now = now
        // Land on what the menu bar number counts, unless today has nothing to show yet.
        _scope = State(initialValue: snapshot.todayCount(for: metric, at: now) > 0 ? .today : .month)
    }

    var body: some View {
        let pullRequests = snapshot.listedPullRequests(for: metric, scope: scope, at: now)
        VStack(alignment: .leading, spacing: 10) {
            Picker("Show", selection: $scope) {
                ForEach(PullRequestScope.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            if pullRequests.isEmpty {
                Text(scope == .today ? "No PRs \(metricVerb) today yet." : "No PRs \(metricVerb) this month.")
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
                        scope == .today
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
