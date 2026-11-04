import SwiftUI
import TallyCore

public struct PopoverView: View {
    @Bindable private var store: TallyStore

    public init(store: TallyStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let snapshot = store.snapshot, let pace = store.pace() {
                progress(pace)
                stats(snapshot: snapshot, pace: pace)
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
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(monthTitle).font(.headline)
            Spacer()
            if let login = store.snapshot?.login {
                Text("@\(login)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var monthTitle: String {
        (store.snapshot?.window.start ?? Date()).formatted(.dateTime.month(.wide).year())
    }

    private func progress(_ pace: Pace) -> some View {
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
            Text(pace.statusText)
                .font(.callout.weight(.medium))
                .foregroundStyle(pace.statusColor)
        }
    }

    private func stats(snapshot: MonthSnapshot, pace: Pace) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Stat(title: "Today", value: snapshot.todayCount(for: store.metric, at: Date()).formatted())
                Stat(title: "Needed / day", value: pace.neededPerDay.formatted(.number.precision(.fractionLength(1))))
                Stat(title: "On track for", value: pace.projected.formatted())
            }
            GridRow {
                let other: PRMetric = store.metric == .opened ? .merged : .opened
                Stat(title: other.title, value: snapshot.count(for: other).formatted())
                Stat(title: "Days left", value: pace.daysRemaining.formatted())
                Stat(title: "Contributions", value: snapshot.totalContributions.formatted())
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let fetchedAt = store.snapshot?.fetchedAt {
                Text("Updated \(fetchedAt.formatted(date: .omitted, time: .shortened))")
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
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit PR Tally")
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
