import Charts
import SwiftUI
import TallyCore

/// Running total against a steady pace, with daily counts underneath on a shared day axis.
/// Clicking a day with pull requests asks for them with its zero-based index.
struct MonthCharts: View {
    let snapshot: MonthSnapshot
    let metric: PRMetric
    let goal: Int
    let now: Date
    var selectDay: (Int) -> Void = { _ in }

    @State private var hoveredDay: Int?

    private static let yLabelWidth: CGFloat = 26
    // Explicit colors: hierarchical styles like `.secondary` pick up the accent tint inside a Chart.
    private static let neutral = Color(nsColor: .secondaryLabelColor)
    private static let grid = Color.primary.opacity(0.08)

    private var dayCount: Int { snapshot.window.dayCount }
    private var daily: [Int] { snapshot.dailyCounts(for: metric) }
    private var cumulative: [Int] { snapshot.cumulativeCounts(for: metric, through: now) }
    private var projection: MonthProjection? { snapshot.projection(for: metric, at: now) }
    /// The plot makes room for a projection past the goal, but not so much that a lumpy early month flattens the line.
    private var yMax: Int {
        max(projection?.ceiling(goal: goal) ?? goal, cumulative.last ?? 0, 1)
    }
    private var xDomain: ClosedRange<Double> { 0.5...(Double(dayCount) + 0.5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("Month so far").font(.caption.weight(.medium))
                    Spacer()
                    LegendKey(label: "You", color: .accentColor, dashed: false)
                    LegendKey(label: "Steady pace", color: Self.neutral, dashed: true)
                }
                if let projection {
                    Text("Likely finish: \(projection.low.formatted())–\(projection.high.formatted())")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                runningTotal.frame(height: 96)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Per day").font(.caption.weight(.medium))
                    Spacer()
                    Text(dailyCaption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                dailyBars.frame(height: 62)
            }
        }
    }

    private var dailyCaption: String {
        guard let hoveredDay, daily.indices.contains(hoveredDay - 1) else {
            return "Best day: \((daily.max() ?? 0).formatted())"
        }
        var text = "\(snapshot.window.dayTitle(hoveredDay - 1)): \(daily[hoveredDay - 1].formatted())"
        if cumulative.indices.contains(hoveredDay - 1) {
            text += ", \(cumulative[hoveredDay - 1].formatted()) total"
        }
        return text
    }

    private var runningTotal: some View {
        Chart {
            LineMark(x: .value("Day", 0.5), y: .value("Pace", 0), series: .value("Series", "Pace"))
                .foregroundStyle(Self.neutral)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            LineMark(x: .value("Day", Double(dayCount) + 0.5), y: .value("Pace", goal), series: .value("Series", "Pace"))
                .foregroundStyle(Self.neutral)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            ForEach(Array(cumulative.enumerated()), id: \.offset) { index, total in
                LineMark(x: .value("Day", Double(index + 1)), y: .value("Total", total), series: .value("Series", "You"))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            projectionRange
            if let last = cumulative.last {
                PointMark(x: .value("Day", Double(cumulative.count)), y: .value("Total", last))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(40)
            }
            hoverRule
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...yMax)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, goal / 2, goal]) { value in
                AxisGridLine().foregroundStyle(Self.grid)
                AxisValueLabel { yLabel(value.as(Int.self) ?? 0) }
            }
        }
        .daySelection($hoveredDay, dayCount: dayCount, select: select)
        .accessibilityLabel(
            "Running total of \(cumulative.last ?? 0) against a steady pace to \(goal)"
                + (projection.map { ". Likely finish \($0.low) to \($0.high)" } ?? "")
        )
    }

    /// A cone from today's total to the likely month-end range, around the line the current rate follows.
    @ChartContentBuilder private var projectionRange: some ChartContent {
        if let projection, let last = cumulative.last {
            let steps = 12
            let startX = Double(cumulative.count)
            let endX = Double(dayCount) + 0.5
            ForEach(0...steps, id: \.self) { step in
                let progress = Double(step) / Double(steps)
                let band = projection.band(at: progress, within: yMax)
                AreaMark(
                    x: .value("Day", startX + (endX - startX) * progress),
                    yStart: .value("Low", band.lowerBound), yEnd: .value("High", band.upperBound),
                    series: .value("Series", "Range")
                )
                .foregroundStyle(Color.accentColor.opacity(0.15))
            }
            LineMark(x: .value("Day", startX), y: .value("Projected", last), series: .value("Series", "Projected"))
                .foregroundStyle(Color.accentColor.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            LineMark(x: .value("Day", endX), y: .value("Projected", min(projection.expected, yMax)), series: .value("Series", "Projected"))
                .foregroundStyle(Color.accentColor.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        }
    }

    private var dailyBars: some View {
        Chart {
            ForEach(Array(daily.enumerated()), id: \.offset) { index, count in
                if count > 0 {
                    BarMark(x: .value("Day", Double(index + 1)), y: .value("Count", count), width: .fixed(6))
                        .foregroundStyle(Color.accentColor)
                        .cornerRadius(2)
                        .opacity(hoveredDay == nil || hoveredDay == index + 1 ? 1 : 0.35)
                }
            }
            hoverRule
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...max(daily.max() ?? 0, 1))
        .chartXAxis {
            AxisMarks(values: [1, 8, 15, 22].map(Double.init)) { value in
                AxisValueLabel { Text(Int(value.as(Double.self) ?? 0), format: .number) }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, max(daily.max() ?? 0, 1)]) { value in
                AxisGridLine().foregroundStyle(Self.grid)
                AxisValueLabel { yLabel(value.as(Int.self) ?? 0) }
            }
        }
        .daySelection($hoveredDay, dayCount: dayCount, select: select)
        .accessibilityLabel("Pull requests per day. \(dailyCaption)")
    }

    /// Days with nothing counted have nothing to list.
    private func select(_ day: Int) {
        guard daily.indices.contains(day - 1), daily[day - 1] > 0 else { return }
        selectDay(day - 1)
    }

    @ChartContentBuilder private var hoverRule: some ChartContent {
        if let hoveredDay {
            RuleMark(x: .value("Day", Double(hoveredDay))).foregroundStyle(Self.neutral)
        }
    }

    /// A fixed width lines both plots up so a day sits at the same x in each chart.
    private func yLabel(_ value: Int) -> some View {
        Text(value >= 1000 ? (Double(value) / 1000).formatted(.number.precision(.fractionLength(0...1))) + "k" : "\(value)")
            .frame(width: Self.yLabelWidth, alignment: .trailing)
            .monospacedDigit()
    }
}

private extension View {
    /// Tracks the day under the pointer, and passes on the one-based day clicked.
    func daySelection(_ day: Binding<Int?>, dayCount: Int, select: @escaping (Int) -> Void) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                let dayAt = { (location: CGPoint) -> Int? in
                    guard let plot = proxy.plotFrame, let value: Double = proxy.value(atX: location.x - geometry[plot].minX)
                    else { return nil }
                    return min(max(Int(value.rounded()), 1), dayCount)
                }
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase else {
                            day.wrappedValue = nil
                            return
                        }
                        day.wrappedValue = dayAt(location)
                    }
                    .onTapGesture { location in dayAt(location).map(select) }
            }
        }
        .help("Click a day to list its PRs")
    }
}

private struct LegendKey: View {
    let label: String
    let color: Color
    let dashed: Bool

    var body: some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 12, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
            .frame(width: 12, height: 2)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// How much of what was opened this month has merged, kept apart from merges of older PRs.
/// Clicking the opened figure asks for the PRs not merged yet, and clicking the older merges asks for those, when there are any.
struct MergeFunnelSummary: View {
    let funnel: MergeFunnel
    var selectNotMerged: () -> Void = {}
    var selectCarriedIn: () -> Void = {}

    var body: some View {
        if !funnel.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if funnel.notMerged > 0 {
                    Button(action: selectNotMerged) { opened.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .help("List the \(funnel.notMerged.formatted()) opened this month that haven't merged")
                } else {
                    opened
                }
                detail
            }
        }
    }

    private var opened: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Opened this month").font(.caption.weight(.medium))
                Spacer()
                Text(funnel.opened > 0 ? "\(funnel.openedAndMerged.formatted()) of \(funnel.opened.formatted()) merged" : "None yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let rate = funnel.mergeRate {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: rate > 0 ? max(geometry.size.width * rate, 4) : 0)
                    }
                }
                .frame(height: 4)
                .help("\(funnel.notMerged.formatted()) not merged, either still open or closed")
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var detail: some View {
        let median = funnel.medianTimeToMerge.map { "median merge \(Self.duration($0))" }
        if funnel.carriedIn > 0 || median != nil {
            HStack(spacing: 0) {
                if funnel.carriedIn > 0 {
                    Button(action: selectCarriedIn) {
                        Text("\(funnel.carriedIn.formatted()) older \(funnel.carriedIn == 1 ? "PR" : "PRs") also merged")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("List the \(funnel.carriedIn.formatted()) merged this month that were opened before it")
                    if median != nil { Text(" · ") }
                }
                if let median { Text(median) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "under 1m" }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 1)
        )
    }
}

/// Clicking a repository asks for its pull requests by name.
struct TopRepositories: View {
    let repositories: [RepoCount]
    var select: (String) -> Void = { _ in }

    var body: some View {
        if let highest = repositories.first?.count, highest > 0 {
            VStack(alignment: .leading, spacing: 5) {
                Text("Top repos").font(.caption.weight(.medium))
                ForEach(repositories) { repository in
                    Button { select(repository.name) } label: { row(repository, highest: highest) }
                        .buttonStyle(.plain)
                        .help("List the PRs in \(repository.name)")
                        .accessibilityLabel("\(repository.name), \(repository.count)")
                }
            }
        }
    }

    private func row(_ repository: RepoCount, highest: Int) -> some View {
        HStack(spacing: 8) {
            Text(repository.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 130, alignment: .leading)
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(geometry.size.width * Double(repository.count) / Double(highest), 4), height: 4)
                    .frame(maxHeight: .infinity)
            }
            Text(repository.count, format: .number)
                .font(.caption)
                .monospacedDigit()
                .frame(minWidth: 24, alignment: .trailing)
        }
        .frame(height: 14)
        .contentShape(Rectangle())
    }
}
