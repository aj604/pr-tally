import AppKit
import SwiftUI
import TallyCore

/// The two counts the list can show, so "what did I merge today" is one choice from the opened list rather than a
/// trip back to the summary. Each option counts what the list would hold after switching, with the same day,
/// repository and status, so the menu never offers a count the list won't show. A merge-funnel part belongs to one
/// metric, so switching to the other drops it rather than leaving a filter that can match nothing.
struct PullRequestWorkspaceMetric: Equatable {
    struct Option: Identifiable, Equatable {
        let metric: PRMetric
        let count: Int
        var id: PRMetric { metric }
        var title: String { "\(PullRequestWorkspaceMetric.name(metric)) (\(count.formatted()))" }
    }

    let options: [Option]

    /// `count` gives how many PRs the list would show for a metric.
    init(count: (PRMetric) -> Int) {
        options = PRMetric.allCases.map { Option(metric: $0, count: count($0)) }
    }

    /// The funnel part the list keeps after switching to `metric`.
    static func funnel(_ funnel: FunnelPart?, keptFor metric: PRMetric) -> FunnelPart? {
        funnel?.metric == metric ? funnel : nil
    }

    static func name(_ metric: PRMetric) -> String { metric == .opened ? "Opened" : "Merged" }
}

/// A pull-down whose closed title names only the metric, so it fits beside the day segment; the menu gives both
/// counts and checks the one showing.
struct PullRequestWorkspaceMetricPicker: NSViewRepresentable {
    let metrics: PullRequestWorkspaceMetric
    @Binding var selection: PRMetric

    func makeNSView(context: Context) -> NSPopUpButton {
        let picker = NSPopUpButton(frame: .zero, pullsDown: true)
        picker.setContentHuggingPriority(.required, for: .horizontal)
        // Gives way before the day segment does, so the row never pushes the list wider than the popover.
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.cell?.lineBreakMode = .byTruncatingTail
        picker.setAccessibilityLabel("Opened or merged")
        picker.toolTip = "Show the PRs opened or the PRs merged"
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.selectMetric(_:))
        return picker
    }

    func updateNSView(_ picker: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        picker.removeAllItems()
        // A pull-down shows its first item as the button's title and leaves it out of the open menu.
        picker.addItem(withTitle: PullRequestWorkspaceMetric.name(selection))
        for option in metrics.options {
            picker.addItem(withTitle: option.title)
            picker.lastItem?.representedObject = option.metric.rawValue
            picker.lastItem?.state = option.metric == selection ? .on : .off
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<PRMetric>

        init(selection: Binding<PRMetric>) { self.selection = selection }

        @objc func selectMetric(_ sender: NSPopUpButton) {
            if let raw = sender.selectedItem?.representedObject as? String, let metric = PRMetric(rawValue: raw) {
                selection.wrappedValue = metric
            }
        }
    }
}

