import AppKit
import SwiftUI
import TallyCore

/// The order the list reads in. Newest first follows the day the metric counts; slowest to merge puts the PRs that
/// took longest from opening to merging at the top, so the ones that held up a day, a repository or the month are the
/// first rows rather than a scan for the biggest "Merged in". It sorts by the exact time each took, not the rounded
/// one the row shows, keeps PRs that took the same time in their newest-first order, and leaves PRs that haven't
/// merged below the merged ones, newest first, since they have no merge time to rank.
enum PullRequestWorkspaceSort: Hashable, CaseIterable {
    case newest, slowestToMerge

    var title: String {
        switch self {
        case .newest: "Newest first"
        case .slowestToMerge: "Slowest to merge"
        }
    }

    /// `pullRequests` come newest first, as `listedPullRequests` gives them.
    func apply(to pullRequests: [PullRequest]) -> [PullRequest] {
        guard self == .slowestToMerge else { return pullRequests }
        let merged = pullRequests.enumerated().compactMap { index, pr in
            pr.mergedAt.map { (pr, $0.timeIntervalSince(pr.createdAt), index) }
        }
        let ranked = merged.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
        return ranked + pullRequests.filter { $0.mergedAt == nil }
    }

    /// Ranking needs two merge times to tell apart, so the menu stays out of the way until the list holds two merged
    /// PRs. A chosen order is always offered, since the menu is also how it is put back.
    static func isOffered(_ selected: Self, for pullRequests: [PullRequest]) -> Bool {
        selected != .newest || pullRequests.lazy.filter { $0.mergedAt != nil }.prefix(2).count == 2
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
