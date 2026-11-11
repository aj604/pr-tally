import Foundation

/// A stretch of a pull request's life as its row words it, rounded to the nearest whole unit: minutes under an hour,
/// hours under a day, and days from there. It never reads less than a minute, so a PR merged the moment it opened, or
/// one whose dates GitHub recorded a little out of order, still says something.
struct PullRequestWorkspaceElapsed: Equatable {
    enum Unit: Equatable { case minutes, hours, days }

    let value: Int
    let unit: Unit

    init(seconds: TimeInterval) {
        let seconds = max(seconds, 0)
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

    /// Short enough to sit beside the row's time: "5h".
    var short: String {
        "\(value.formatted())\(unit == .minutes ? "m" : unit == .hours ? "h" : "d")"
    }

    /// `short` in words, since "5h" is written shorthand: "5 hours".
    var spoken: String {
        let noun = switch unit {
        case .minutes: value == 1 ? "minute" : "minutes"
        case .hours: value == 1 ? "hour" : "hours"
        case .days: value == 1 ? "day" : "days"
        }
        return "\(value.formatted()) \(noun)"
    }
}
