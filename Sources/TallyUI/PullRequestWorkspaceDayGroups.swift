import Foundation
import TallyCore

/// The whole month's list split into one section per day, newest day first, so each row needs only its time and a
/// day's PRs read as a unit. A section is named the way the day segment names it ("Today" or e.g. "Nov 7"), since
/// clicking its header opens that day there. Rows keep the order they came in within their day, and a day with no
/// listed PR has no section.
struct PullRequestWorkspaceDayGroups: Equatable {
    let groups: [Group]

    struct Group: Equatable, Identifiable {
        /// Zero-based day of the month.
        let day: Int
        let title: String
        let pullRequests: [PullRequest]

        var id: Int { day }

        /// The section's count, short enough to sit beside its title.
        var countText: String {
            "\(pullRequests.count.formatted()) \(pullRequests.count == 1 ? "PR" : "PRs")"
        }
    }

    /// `pullRequests` are grouped by the date `metric` counts them on, in the zone the month was counted in; any not
    /// counted inside the month are left out, as the list never shows them.
    init(_ pullRequests: [PullRequest], metric: PRMetric, in window: MonthWindow, at now: Date) {
        let today = window.dayIndex(of: now)
        var byDay: [Int: [PullRequest]] = [:]
        for pr in pullRequests {
            guard let date = metric == .opened ? pr.createdAt : pr.mergedAt, let day = window.dayIndex(of: date)
            else { continue }
            byDay[day, default: []].append(pr)
        }
        groups = byDay.keys.sorted(by: >).map { day in
            Group(day: day, title: day == today ? "Today" : window.dayTitle(day), pullRequests: byDay[day]!)
        }
    }
}
