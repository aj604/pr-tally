import AppKit
import SwiftUI
import TallyCore

/// Narrows the list to the PRs a row label names ("Draft", "Needs review", ...), so "what is waiting on review" is
/// one choice rather than a scan. A PR whose state isn't known (a snapshot saved before states were fetched, which
/// is what a relaunch shows until the first refresh) matches no label, so it gets its own choice and its own count
/// instead of silently dropping out of the others.
struct PullRequestWorkspaceStatusFilter: Equatable {
    enum Choice: Hashable {
        case status(PullRequestWorkspaceStatus.Kind)
        case review(PullRequest.ReviewDecision)
        case checksFailing
        case unknown

        func matches(_ pr: PullRequest) -> Bool {
            switch self {
            case .status(let kind): PullRequestWorkspaceStatus(pr)?.kind == kind
            case .review(let decision): PullRequestWorkspaceReview(pr)?.decision == decision
            case .checksFailing: PullRequestWorkspaceChecks(pr) != nil
            case .unknown: PullRequestWorkspaceStatus(pr) == nil
            }
        }

        /// Whether the menu sets this choice apart from the one above it: review and checks each answer a different
        /// question from where the PR stands.
        var startsGroup: Bool {
            switch self {
            case .review, .checksFailing: true
            case .status, .unknown: false
            }
        }

        var title: String {
            switch self {
            case .status(.open): "Open"
            case .status(.draft): "Draft"
            case .status(.merged): "Merged"
            case .status(.closed): "Closed"
            case .review(.reviewRequired): "Needs review"
            case .review(.changesRequested): "Changes requested"
            case .review(.approved): "Approved"
            case .checksFailing: "CI failing"
            case .unknown: "Status not known yet"
            }
        }
    }

    struct Option: Identifiable, Equatable {
        let choice: Choice
        let count: Int
        var id: Choice { choice }
        var title: String { "\(choice.title) (\(count.formatted()))" }
    }

    /// Choices in reading order: where the PR stands, then where review stands, then whether checks fail, then what isn't known.
    static let order: [Choice] = [
        .status(.open), .status(.draft), .status(.merged), .status(.closed),
        .review(.reviewRequired), .review(.changesRequested), .review(.approved),
        .checksFailing, .unknown,
    ]

    let options: [Option]
    let totalCount: Int
    private let selected: Choice?

    /// Only choices some PR matches are offered, plus `selected`, which stays visible and removable when a different
    /// day or repository leaves it empty.
    init(_ pullRequests: [PullRequest], selected: Choice? = nil) {
        options = Self.order.compactMap { choice in
            let count = pullRequests.filter(choice.matches).count
            return count > 0 || choice == selected ? Option(choice: choice, count: count) : nil
        }
        totalCount = pullRequests.count
        self.selected = selected
    }

    /// A filter has nothing to tell apart when every PR is the same thing (the merged list, or a list of PRs with no
    /// recorded state), so the picker stays out of the way until there are two kinds of PR.
    /// An active filter is always offered, since the picker is also how it is removed.
    var isOffered: Bool { selected != nil || options.count >= 2 }

    static func apply(_ choice: Choice?, to pullRequests: [PullRequest]) -> [PullRequest] {
        choice.map { choice in pullRequests.filter(choice.matches) } ?? pullRequests
    }
}

/// A native menu like the repository picker, so the two sit side by side and read the same.
struct PullRequestWorkspaceStatusPicker: NSViewRepresentable {
    let filter: PullRequestWorkspaceStatusFilter
    @Binding var selection: PullRequestWorkspaceStatusFilter.Choice?

    func makeNSView(context: Context) -> NSPopUpButton {
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.cell?.lineBreakMode = .byTruncatingTail
        picker.setAccessibilityLabel("Status")
        picker.toolTip = "Filter this list by status or review"
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.selectStatus(_:))
        return picker
    }

    func updateNSView(_ picker: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        picker.removeAllItems()
        picker.addItem(withTitle: "All statuses")
        var previous: PullRequestWorkspaceStatusFilter.Choice?
        for option in filter.options {
            // Review and checks are different questions from state, so each group gets a rule above it.
            if option.choice.startsGroup, !Self.sameGroup(previous, option.choice) { picker.menu?.addItem(.separator()) }
            picker.addItem(withTitle: option.title)
            picker.lastItem?.representedObject = option.choice
            previous = option.choice
        }
        let index = picker.itemArray.firstIndex { ($0.representedObject as? PullRequestWorkspaceStatusFilter.Choice) == selection && selection != nil }
        picker.selectItem(at: index ?? 0)
    }

    private static func sameGroup(_ previous: PullRequestWorkspaceStatusFilter.Choice?, _ choice: PullRequestWorkspaceStatusFilter.Choice) -> Bool {
        if case .review = previous, case .review = choice { true } else { false }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<PullRequestWorkspaceStatusFilter.Choice?>

        init(selection: Binding<PullRequestWorkspaceStatusFilter.Choice?>) { self.selection = selection }

        @objc func selectStatus(_ sender: NSPopUpButton) {
            selection.wrappedValue = sender.selectedItem?.representedObject as? PullRequestWorkspaceStatusFilter.Choice
        }
    }
}
