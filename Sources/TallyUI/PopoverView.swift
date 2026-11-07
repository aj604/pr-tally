import SwiftUI
import TallyCore

public struct PopoverView: View {
    @Bindable private var store: TallyStore
    /// What the pull request list opens narrowed to, set by whatever opened it.
    @State private var listFocus = PullRequestFocus()

    public init(store: TallyStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if store.screen == .settings {
                SettingsView(store: store)
            } else if store.screen == .pullRequests, let snapshot = store.currentSnapshot() {
                PullRequestList(snapshot: snapshot, metric: store.metric, now: Date(), focus: listFocus)
            } else if let snapshot = store.currentSnapshot(), let pace = store.pace() {
                progress(pace, today: snapshot.todayCount(for: store.metric, at: Date()))
                stats(snapshot: snapshot, pace: pace)
                pullRequestsButton(snapshot)
                Divider()
                MonthCharts(snapshot: snapshot, metric: store.metric, goal: store.goal, now: Date()) { day in
                    showPullRequests(PullRequestFocus(day: day))
                }
                MergeFunnelSummary(funnel: snapshot.mergeFunnel) {
                    showPullRequests(PullRequestFocus(metric: .opened, notMerged: true))
                }
                TopRepositories(repositories: snapshot.topRepositories(for: store.metric)) { repository in
                    showPullRequests(PullRequestFocus(repository: repository))
                }
            } else if let summary = store.lastMonthSummary() {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waiting for \(Date().formatted(.dateTime.month(.wide)))'s numbers.").font(.callout)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if store.errorMessage == nil {
                ProgressView("Counting your PRs…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(16)
        .frame(width: 320)
        .task { await store.refreshIfStale() }
        // `MenuBarExtra` keeps this view alive between openings, with its state, so the reset is explicit.
        .onDisappear {
            store.popoverClosed()
            listFocus = PullRequestFocus()
        }
    }

    private func showPullRequests(_ focus: PullRequestFocus = PullRequestFocus()) {
        listFocus = focus
        store.screen = .pullRequests
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if store.screen == .pullRequests, store.currentSnapshot() != nil {
                Button {
                    store.screen = .summary
                } label: {
                    Label(monthTitle, systemImage: "chevron.left").font(.headline)
                }
                .buttonStyle(.plain)
                .help("Back to the month")
            } else {
                Text(monthTitle).font(.headline)
            }
            Spacer()
            if let login = store.snapshot?.login {
                Text("@\(login)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var monthTitle: String { store.monthTitle() }

    private func progress(_ pace: Pace, today: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(pace.count, format: .number)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("of \(pace.goal.formatted()) \(store.metric.noun)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            PaceBar(pace: pace)
            HStack(alignment: .firstTextBaseline) {
                Text(pace.statusText)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(pace.statusColor)
                Spacer(minLength: 8)
                let note = TodayNote(pace: pace, today: today)
                // Both together rarely fit beside the status at full length, so the quota's name shortens first.
                ViewThatFits(in: .horizontal) {
                    todayNote(note, pace: pace, today: today, quota: "today's quota")
                    todayNote(note, pace: pace, today: today, quota: "quota")
                }
            }
        }
    }

    private func todayNote(_ note: TodayNote, pace: Pace, today: Int, quota: String) -> some View {
        HStack(spacing: 8) {
            if let over = note.overQuota {
                Label("\(over.formatted()) over \(quota)", systemImage: "arrow.up.right")
                    .foregroundStyle(.green)
                    .help("Today's count beat the \(pace.dailyQuota.formatted(.number.precision(.fractionLength(0...1)))) a day a steady pace needs")
            }
            if let more = note.moreToday {
                Text("\(more.formatted()) more today")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("\(today.formatted()) of today's \((today + more).formatted()), the share that keeps the goal in reach")
            }
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .fixedSize()
    }

    private func stats(snapshot: MonthSnapshot, pace: Pace) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                let today = snapshot.todayCount(for: store.metric, at: Date())
                Stat(title: "Today", value: today.formatted())
                Stat(title: "Needed / day", value: pace.neededPerDay(today: today).formatted(.number.precision(.fractionLength(1))))
                Stat(title: "On track for", value: pace.projected.formatted())
            }
            GridRow {
                otherMetric(snapshot)
                Stat(title: "Days left", value: pace.daysRemaining.formatted())
                Stat(title: "Contributions", value: snapshot.totalContributions.formatted())
            }
        }
    }

    /// The count the goal doesn't follow, listing its PRs when clicked.
    @ViewBuilder private func otherMetric(_ snapshot: MonthSnapshot) -> some View {
        let other: PRMetric = store.metric == .opened ? .merged : .opened
        let count = snapshot.count(for: other)
        let stat = Stat(title: other.title, value: count.formatted())
        if count > 0 {
            Button { showPullRequests(PullRequestFocus(metric: other)) } label: { stat.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("List the \(count.formatted()) \(other.noun)")
        } else {
            stat
        }
    }

    private func pullRequestsButton(_ snapshot: MonthSnapshot) -> some View {
        Button {
            showPullRequests()
        } label: {
            HStack {
                Text("See the \(snapshot.count(for: store.metric).formatted()) PRs").font(.callout)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("List the pull requests behind these numbers")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let updated = store.updatedText() {
                Text(updated)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
            .help("Refresh now")
            .accessibilityLabel("Refresh now")
            Button {
                store.screen = store.screen == .settings ? .summary : .settings
            } label: {
                Image(systemName: store.screen == .settings ? "gearshape.fill" : "gearshape")
            }
            .help("Settings")
            .accessibilityLabel("Settings")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit PR Tally")
            .accessibilityLabel("Quit PR Tally")
        }
        .buttonStyle(.borderless)
    }
}

/// Progress toward the goal, with a tick where a steady pace would be today.
private struct PaceBar: View {
    let pace: Pace

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(pace.statusColor)
                    .frame(width: max(width * pace.fraction, pace.count > 0 ? 8 : 0))
                if pace.goal > 0, pace.status != .goalHit {
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: 14)
                        .offset(x: min(width * Double(pace.expected) / Double(pace.goal), width - 2))
                }
            }
        }
        .frame(height: 8)
        .padding(.vertical, 3)
        .accessibilityElement()
        .accessibilityLabel("\(pace.count) of \(pace.goal). \(pace.statusText)")
    }
}

private struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the line under the progress bar says about today, beside the pace status: how far today is past the fixed
/// daily quota a steady pace needs, and how many more PRs today needs for its share of what is left of the goal.
/// Behind pace, today's share is more than the quota, so a day can beat the quota and still fall short of its share.
/// Then both show: the quota is what turns the menu bar number green, and the share is what keeps the goal in reach.
struct TodayNote: Equatable {
    /// Whole PRs past the daily quota, or nil when today hasn't passed it.
    let overQuota: Int?
    /// Whole PRs still to count today for today's share, or nil once today has it.
    let moreToday: Int?

    init(pace: Pace, today: Int) {
        let surplus = pace.quotaSurplus(today: today)
        let left = pace.leftToday(today: today)
        overQuota = surplus > 0 ? surplus : nil
        moreToday = left > 0 ? left : nil
    }
}

extension PRMetric {
    var title: String { self == .opened ? "Opened" : "Merged" }
    var noun: String { self == .opened ? "PRs opened" : "PRs merged" }
}

extension Pace {
    var statusText: String {
        switch status {
        case .goalHit: "Goal hit 🎉"
        case .ahead: "\(delta.formatted()) ahead of pace"
        case .onPace: "Right on pace"
        case .behind: "\((-delta).formatted()) behind pace"
        }
    }

    var statusColor: Color {
        switch status {
        case .goalHit, .ahead, .onPace: .green
        case .behind: .orange
        }
    }
}
