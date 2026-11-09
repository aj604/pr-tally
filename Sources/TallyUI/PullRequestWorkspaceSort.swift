import AppKit
import SwiftUI
import TallyCore

/// The order the list reads in. Newest first follows the day the metric counts; slowest to merge puts the PRs that
/// took longest from opening to merging at the top, so the ones that held up a day, a repository or the month are the
/// first rows rather than a scan for the biggest "Merged in". A PR still open or in draft ranks by how long it has been
/// waiting so far, among the merged ones: one open for six days has already been slower to merge than one merged in
/// two. It sorts by exact times, not the rounded ones the rows show, keeps PRs that took the same time in their
/// newest-first order, and leaves PRs with no time to rank (closed without merging, or of a state not known yet)
/// at the bottom, newest first.
enum PullRequestWorkspaceSort: Hashable, CaseIterable {
    case newest, slowestToMerge

    var title: String {
        switch self {
        case .newest: "Newest first"
        case .slowestToMerge: "Slowest to merge"
        }
    }

    /// `pullRequests` come newest first, as `listedPullRequests` gives them; `now` is when an open PR's wait ends.
    func apply(to pullRequests: [PullRequest], at now: Date) -> [PullRequest] {
        guard self == .slowestToMerge else { return pullRequests }
        let timed = pullRequests.enumerated().compactMap { index, pr in
            Self.timeToMerge(pr, at: now).map { (pr, $0, index) }
        }
        let ranked = timed.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
        return ranked + pullRequests.filter { Self.timeToMerge($0, at: now) == nil }
    }

    /// Ranking needs two times to tell apart, so the menu stays out of the way until the list holds two PRs that are
    /// merged or still open. A chosen order is always offered, since the menu is also how it is put back.
    static func isOffered(_ selected: Self, for pullRequests: [PullRequest], at now: Date) -> Bool {
        selected != .newest || pullRequests.lazy.filter { timeToMerge($0, at: now) != nil }.prefix(2).count == 2
    }

    /// From opening to merging, or to `now` for a PR still waiting; nil when the PR has no such time.
    private static func timeToMerge(_ pr: PullRequest, at now: Date) -> TimeInterval? {
        if let mergedAt = pr.mergedAt { return mergedAt.timeIntervalSince(pr.createdAt) }
        return PullRequestWorkspaceOpenTime(pr, at: now) == nil ? nil : now.timeIntervalSince(pr.createdAt)
    }

    /// Whether the whole month splits into days in this order. Slowest to merge ranks across the month, so its rows
    /// carry their own day instead.
    var groupsByDay: Bool { self == .newest }
}

/// An icon pull-down like the copy button beside it, so ordering the list costs no row; the menu names each order and
/// checks the one showing.
struct PullRequestWorkspaceSortPicker: NSViewRepresentable {
    @Binding var selection: PullRequestWorkspaceSort

    func makeNSView(context: Context) -> NSPopUpButton {
        let picker = NSPopUpButton(frame: .zero, pullsDown: true)
        picker.isBordered = false
        (picker.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        picker.imagePosition = .imageOnly
        picker.contentTintColor = .secondaryLabelColor
        picker.setAccessibilityLabel("Sort")
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.selectSort(_:))
        return picker
    }

    func updateNSView(_ picker: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        picker.removeAllItems()
        // A pull-down shows its first item as the button and leaves it out of the open menu.
        picker.addItem(withTitle: "")
        picker.lastItem?.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
        for order in PullRequestWorkspaceSort.allCases {
            picker.addItem(withTitle: order.title)
            picker.lastItem?.representedObject = order.title
            picker.lastItem?.state = order == selection ? .on : .off
        }
        picker.toolTip = "Sort this list: \(selection.title)"
        picker.setAccessibilityValue(selection.title)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<PullRequestWorkspaceSort>

        init(selection: Binding<PullRequestWorkspaceSort>) { self.selection = selection }

        @objc func selectSort(_ sender: NSPopUpButton) {
            let title = sender.selectedItem?.representedObject as? String
            if let order = PullRequestWorkspaceSort.allCases.first(where: { $0.title == title }) {
                selection.wrappedValue = order
            }
        }
    }
}
