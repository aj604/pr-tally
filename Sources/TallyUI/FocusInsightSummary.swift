import SwiftUI
import TallyCore

/// Above the pull request list when it opened on a slice of the month: names the slice, says what it amounts to
/// beside the month, and for a day steps to the day before or after without going back to the charts.
struct FocusInsightSummary: View {
    let snapshot: MonthSnapshot
    /// The metric the goal counts; the focus can ask for the other.
    let metric: PRMetric
    let focus: PullRequestFocus
    let now: Date
    var step: (PullRequestFocus) -> Void = { _ in }

    var body: some View {
        if let text = FocusInsightText(snapshot: snapshot, metric: metric, focus: focus, now: now) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(text.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if focus.day != nil {
                        stepButton("chevron.left", to: text.previousDay, help: "Show the day before")
                        stepButton("chevron.right", to: text.nextDay, help: "Show the day after")
                    }
                }
                ForEach(text.lines, id: \.self) { Text($0) }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(text.help)
        }
    }

    private func stepButton(_ symbol: String, to day: Int?, help: String) -> some View {
        Button {
            var next = focus
            next.day = day
            step(next)
        } label: {
            Image(systemName: symbol).font(.caption.weight(.semibold)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(day == nil)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The words for a slice: a title saying where the list is zoomed to, then what the slice amounts to, how its PRs
/// stand, and where they are. Nil for the unfocused list, which is the whole month the summary already describes.
struct FocusInsightText: Equatable {
    let title: String
    let lines: [String]
    let help: String
    /// The neighbouring days a day's slice steps to, nil at the month's first day or at today.
    let previousDay: Int?
    let nextDay: Int?

    init?(snapshot: MonthSnapshot, metric goal: PRMetric, focus: PullRequestFocus, now: Date) {
        guard focus.day != nil || focus.repository != nil || focus.metric != nil || focus.funnel != nil else { return nil }
        let metric = focus.listedMetric(goal: goal)
        let window = snapshot.window
        let slice = snapshot.listedPullRequests(
            for: metric, scope: focus.day.map { .day($0) } ?? .month, repository: focus.repository,
            funnel: focus.funnel, at: now
        )
        let insight = FocusInsight(pullRequests: slice, monthCount: snapshot.count(for: metric))
        let verb = metric.rawValue
        let today = window.dayIndex(of: now)

        var titles: [String] = []
        if let day = focus.day { titles.append(day == today ? "Today" : Self.dayTitle(day, in: window)) }
        if let repository = focus.repository { titles.append(repository) }
        switch focus.funnel {
        case .notMerged: titles.append("Opened, not merged")
        case .carriedIn: titles.append("Opened before \(window.monthTitle)")
        case nil: if titles.isEmpty { titles.append("\(metric.title) this month") }
        }
        title = titles.joined(separator: " · ")

        var lines: [String] = []
        if focus.day != nil, let average = snapshot.averagePerDay(for: metric, at: now), average > 0 {
            let ratio = Double(insight.count) / average
            let size = insight.count == 0 ? "None \(verb)" : "\(insight.count.formatted()) \(verb)"
            let compared = ratio == 0 ? "an average day has \(average.formatted(.number.precision(.fractionLength(0...1))))"
                : (0.9...1.1).contains(ratio) ? "about an average day"
                : "\(ratio.formatted(.number.precision(.fractionLength(0...1))))× an average day"
            lines.append("\(size) · \(compared)")
        } else if let share = insight.share, insight.count < insight.monthCount {
            lines.append("\(insight.count.formatted()) of \(insight.monthCount.formatted()) \(verb) this month · \(share.formatted(.percent.precision(.fractionLength(0))))")
        } else {
            lines.append("\(insight.count.formatted()) \(verb) this month")
        }

        var standing: [String] = []
        if let median = insight.medianTimeToMerge {
            standing.append(metric == .opened
                ? "\(insight.merged.formatted()) merged in a median \(Self.duration(median))"
                : "Median \(Self.duration(median)) from open to merge")
        }
        if insight.open > 0 { standing.append("\(insight.open.formatted()) open") }
        if insight.draft > 0 { standing.append("\(insight.draft.formatted()) draft") }
        if insight.closed > 0 { standing.append("\(insight.closed.formatted()) closed") }
        if !standing.isEmpty { lines.append(standing.joined(separator: " · ")) }

        let repositories = insight.repositories
        if focus.repository == nil, let top = repositories.first {
            if repositories.count == 1 {
                lines.append("All in \(top.name)")
            } else if top.count > repositories[1].count {
                lines.append("\(repositories.count.formatted()) repos, most in \(top.name) (\(top.count.formatted()))")
            } else {
                lines.append("\(repositories.count.formatted()) repos")
            }
        }
        self.lines = lines

        help = "Compared with every PR \(verb) this month. Merge times run from opening to merging; "
            + "open, draft and closed count only PRs whose state GitHub reported."
        if let day = focus.day {
            let last = today ?? (now >= window.end ? window.dayCount - 1 : 0)
            previousDay = day > 0 ? day - 1 : nil
            nextDay = day < last ? day + 1 : nil
        } else {
            previousDay = nil
            nextDay = nil
        }
    }

    /// A zero-based day with its weekday, in the zone the month was counted in, since "Tue" says more than "Nov 3".
    static func dayTitle(_ day: Int, in window: MonthWindow) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = window.calendar.timeZone
        return window.calendar.date(byAdding: .day, value: day, to: window.start)!.formatted(style)
    }

    /// A span short enough to read at a glance: minutes under an hour, hours under two days, then days.
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        let hours = interval / 3_600
        if hours < 47.5 { return "\(Int(hours.rounded()))h" }
        return "\((hours / 24).formatted(.number.precision(.fractionLength(0...1)))) days"
    }
}
