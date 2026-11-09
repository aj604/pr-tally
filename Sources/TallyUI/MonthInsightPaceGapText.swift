import TallyCore

/// The line under the stats grid that sets the needed daily count against the recent one.
struct MonthInsightPaceGapText: Equatable {
    let line: String
    let help: String

    init(gap: MonthInsightPaceGap) {
        let rate = Self.perDay(gap.recent)
        let needed = Self.perDay(gap.needed)
        let recent = "Recent pace \(rate) a day"
        switch gap.verdict {
        case .covered:
            line = "\(recent) · enough for the \(needed) needed"
        case .stretch, .steepClimb:
            // No multiple when nothing was counted recently: "needs infinitely more" says nothing.
            let multiple = gap.multiple.map { " · needs \(Self.times($0)) that" } ?? ""
            line = "\(recent)\(multiple)"
        }
        help = "The goal needs \(needed) a day from the start of today. The last \(gap.days) completed days "
            + "averaged \(rate) a day; today is left out so a quiet morning doesn't look like a slowdown."
    }

    private static func perDay(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// "1.3×" up to ten times, then a whole number, so "41.7×" doesn't pose as precision.
    private static func times(_ value: Double) -> String {
        let text = value < 10
            ? value.formatted(.number.precision(.fractionLength(1)))
            : value.formatted(.number.precision(.fractionLength(0)))
        return "\(text)×"
    }
}
