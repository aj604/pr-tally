import Charts
import SwiftUI
import TallyCore

/// Running total against a steady pace, with daily counts underneath on a shared day axis.
struct MonthCharts: View {
    let snapshot: MonthSnapshot
    let metric: PRMetric
    let goal: Int
    let now: Date

    @State private var hoveredDay: Int?

    private static let yLabelWidth: CGFloat = 26
    // Explicit colors: hierarchical styles like `.secondary` pick up the accent tint inside a Chart.
    private static let neutral = Color(nsColor: .secondaryLabelColor)
    private static let grid = Color.primary.opacity(0.08)

    private var dayCount: Int { snapshot.window.dayCount }
    private var daily: [Int] { snapshot.dailyCounts(for: metric) }
    private var cumulative: [Int] { snapshot.cumulativeCounts(for: metric, through: now) }
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
            MergeFunnelSummary(funnel: snapshot.mergeFunnel)
        }
    }

    private var dailyCaption: String {
        guard let hoveredDay, daily.indices.contains(hoveredDay - 1) else {
            return "Best day: \((daily.max() ?? 0).formatted())"
        }
        let date = snapshot.window.calendar.date(byAdding: .day, value: hoveredDay - 1, to: snapshot.window.start)!
        var text = "\(date.formatted(.dateTime.month(.abbreviated).day())): \(daily[hoveredDay - 1].formatted())"
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
            if let last = cumulative.last {
                PointMark(x: .value("Day", Double(cumulative.count)), y: .value("Total", last))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(40)
            }
            hoverRule
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...max(goal, cumulative.last ?? 0, 1))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, goal / 2, goal]) { value in
                AxisGridLine().foregroundStyle(Self.grid)
                AxisValueLabel { yLabel(value.as(Int.self) ?? 0) }
            }
        }
        .hoverSelection($hoveredDay, dayCount: dayCount)
        .accessibilityLabel("Running total of \(cumulative.last ?? 0) against a steady pace to \(goal)")
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
        .hoverSelection($hoveredDay, dayCount: dayCount)
        .accessibilityLabel("Pull requests per day. \(dailyCaption)")
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
    /// Tracks the day under the pointer.
    func hoverSelection(_ day: Binding<Int?>, dayCount: Int) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase, let plot = proxy.plotFrame,
                            let value: Double = proxy.value(atX: location.x - geometry[plot].minX)
                        else {
                            day.wrappedValue = nil
                            return
                        }
                        day.wrappedValue = min(max(Int(value.rounded()), 1), dayCount)
                    }
            }
        }
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
private struct MergeFunnelSummary: View {
    let funnel: MergeFunnel

    var body: some View {
        if !funnel.isEmpty {
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
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if funnel.carriedIn > 0 {
            parts.append("\(funnel.carriedIn.formatted()) older \(funnel.carriedIn == 1 ? "PR" : "PRs") also merged")
        }
        if let median = funnel.medianTimeToMerge {
            parts.append("median merge \(Self.duration(median))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "under 1m" }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 1)
        )
    }
}

struct TopRepositories: View {
    let repositories: [RepoCount]

    var body: some View {
        if let highest = repositories.first?.count, highest > 0 {
            VStack(alignment: .leading, spacing: 5) {
                Text("Top repos").font(.caption.weight(.medium))
                ForEach(repositories) { repository in
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
                }
            }
        }
    }
}
