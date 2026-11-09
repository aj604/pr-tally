import SwiftUI
import TallyCore

/// How long a merged pull request took from opening to merging, worn on its row, so a slow day or repository shows
/// which PRs held it up. It stands in for the plain "Merged" label in the opened list, and gives the merged list, which
/// otherwise leaves that label out, something to say. The time is rounded to the nearest whole unit, in minutes under an
/// hour, hours under a day, and days from there, and never reads less than a minute.
struct PullRequestWorkspaceMergeTime: Equatable {
    enum Unit: Equatable { case minutes, hours, days }

    let value: Int
    let unit: Unit

    init?(_ pr: PullRequest) {
        guard let mergedAt = pr.mergedAt else { return nil }
        let seconds = max(mergedAt.timeIntervalSince(pr.createdAt), 0)
        let minutes = Int((seconds / 60).rounded())
        let hours = Int((seconds / 3_600).rounded())
        if minutes < 60 {
            (value, unit) = (max(minutes, 1), .minutes)
        } else if hours < 24 {
            (value, unit) = (hours, .hours)
        } else {
            (value, unit) = (Int((seconds / 86_400).rounded()), .days)
        }
    }

    /// Short enough to sit beside the row's time: "Merged in 5h".
    var label: String {
        "Merged in \(value.formatted())\(unit == .minutes ? "m" : unit == .hours ? "h" : "d")"
    }

    /// `label` read out in words, since "5h" is written shorthand.
    var accessibilityLabel: String {
        let noun = switch unit {
        case .minutes: value == 1 ? "minute" : "minutes"
        case .hours: value == 1 ? "hour" : "hours"
        case .days: value == 1 ? "day" : "days"
        }
        return "Merged in \(value.formatted()) \(noun)"
    }

    /// The merged status's colour, as the label replaces it.
    var tint: Color { .purple }
}
