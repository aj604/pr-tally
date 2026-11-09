import SwiftUI
import TallyCore

/// Above the pull request list when it opened on a slice of the month: names the slice and says what it amounts to
/// beside the month.
struct FocusInsightSummary: View {
    let snapshot: MonthSnapshot
    /// The metric the goal counts; the focus can ask for the other.
    let metric: PRMetric
    let focus: PullRequestFocus
    let now: Date

    var body: some View {
        if let text = FocusInsightText(snapshot: snapshot, metric: metric, focus: focus, now: now) {
            VStack(alignment: .leading, spacing: 3) {
                Text(text.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                ForEach(text.lines, id: \.self) { Text($0) }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(text.help)
        }
    }
}

/// The words for a slice: a title saying where the list is zoomed to, then what the slice amounts to, how its PRs
/// stand, how big they run beside the month's, and where they are. Nil for the unfocused list, which is the whole month
/// the summary already describes.
struct FocusInsightText: Equatable {
    let title: String
    let lines: [String]
    let help: String

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

        if let size = insight.medianLinesChanged {
            let median = "Median \(Self.lineCount(size)) changed"
            // Beside the month only when the slice is a part of it: the whole month is always its own size.
            if insight.count < insight.monthCount, let month = snapshot.medianLinesChanged(for: metric), month > 0 {
                let ratio = size / month
                let monthLines = Int(month.rounded()).formatted()
                // A ratio under one reads as "0.1×" or worse, "0×", so smaller slices just say so.
                lines.append("\(median) · " + ((0.9...1.1).contains(ratio) ? "about the month's \(monthLines)"
                    : ratio < 1 ? "under the month's \(monthLines)"
                    : "\(ratio.formatted(.number.precision(.fractionLength(0...1))))× the month's \(monthLines)"))
            } else {
                lines.append(median)
            }
        }

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
            + "open, draft and closed count only PRs whose state GitHub reported. Size is lines added plus deleted."
    }

    /// A zero-based day with its weekday, in the zone the month was counted in, since "Tue" says more than "Nov 3".
    static func dayTitle(_ day: Int, in window: MonthWindow) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = window.calendar.timeZone
        return window.calendar.date(byAdding: .day, value: day, to: window.start)!.formatted(style)
    }

    /// A median size in whole lines, since half a line means nothing.
    static func lineCount(_ lines: Double) -> String {
        let count = Int(lines.rounded())
        return "\(count.formatted()) \(count == 1 ? "line" : "lines")"
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
