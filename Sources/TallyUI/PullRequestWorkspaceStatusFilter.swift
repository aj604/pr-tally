import AppKit
import SwiftUI
import TallyCore

/// Narrows the list to the PRs a row label names ("Draft", "Needs review", ...), so "what is waiting on review" is
/// one choice rather than a scan. A PR whose state isn't known (a snapshot saved before states were fetched, which
/// is what a relaunch shows until the first refresh) matches no label, so it gets its own choice and its own count
/// instead of silently dropping out of the others.
///
/// A part of the merge funnel ("Not merged", "Older PRs") is one more choice in the same menu rather than a
/// filter of its own, so the list opened from the funnel spends no row on it and either part can be picked from inside
/// the list. Which PRs a part holds depends on the whole month, not on the PR, so the caller passes its members.
struct PullRequestWorkspaceStatusFilter: Equatable {
    /// The ids of the PRs in each funnel part the list's metric counts.
    typealias FunnelMembers = [FunnelPart: Set<String>]

    enum Choice: Hashable {
        case funnel(FunnelPart)
        case status(PullRequestWorkspaceStatus.Kind)
        case review(PullRequest.ReviewDecision)
        case checksFailing
        case unknown

        func matches(_ pr: PullRequest, funnel members: FunnelMembers = [:]) -> Bool {
            switch self {
            case .funnel(let part): members[part]?.contains(pr.id) ?? false
            case .status(let kind): PullRequestWorkspaceStatus(pr)?.kind == kind
            case .review(let decision): PullRequestWorkspaceReview(pr)?.decision == decision
            case .checksFailing: PullRequestWorkspaceChecks(pr) != nil
            case .unknown: PullRequestWorkspaceStatus(pr) == nil
            }
        }

        /// The funnel part this choice is, if it is one.
        var funnelPart: FunnelPart? {
            if case .funnel(let part) = self { part } else { nil }
        }

        /// Whether the menu sets this choice apart from the one above it: review and checks each answer a different
        /// question from where the PR stands.
        var startsGroup: Bool {
            switch self {
            case .review, .checksFailing: true
            case .funnel, .status, .unknown: false
            }
        }

        var title: String {
            switch self {
            case .funnel(.notMerged): "Not merged"
            // Named as the summary's link to it names them ("2 older PRs also merged"), and short enough for the picker.
            case .funnel(.carriedIn): "Older PRs"
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

    /// The funnel parts `metric` counts, with the PRs in each.
    static func funnelMembers(for metric: PRMetric, in snapshot: MonthSnapshot) -> FunnelMembers {
        Dictionary(uniqueKeysWithValues: [FunnelPart.notMerged, .carriedIn].filter { $0.metric == metric }.map {
            ($0, Set($0.pullRequests(in: snapshot).map(\.id)))
        })
    }

    /// Choices in reading order: where the PR stands, then where review stands, then whether checks fail, then what
    /// isn't known. Funnel parts lead, above them, when the metric has any.
    static let order: [Choice] = [
        .status(.open), .status(.draft), .status(.merged), .status(.closed),
        .review(.reviewRequired), .review(.changesRequested), .review(.approved),
        .checksFailing, .unknown,
    ]

    let options: [Option]
    let totalCount: Int
    private let selected: Choice?

    /// Only choices some PR matches are offered, plus `selected`, which stays visible and removable when a different
    /// day or repository leaves it empty. A funnel part that holds every PR in the list, or none, tells nothing apart
    /// (every PR opened today may be unmerged), so it is offered only while it narrows the list or is selected.
    init(_ pullRequests: [PullRequest], funnel members: FunnelMembers = [:], selected: Choice? = nil) {
        let parts = [FunnelPart.notMerged, .carriedIn].filter { members[$0] != nil }.map(Choice.funnel)
        options = (parts + Self.order).compactMap { choice in
            let count = pullRequests.filter { choice.matches($0, funnel: members) }.count
            let narrows = choice.funnelPart == nil ? count > 0 : count > 0 && count < pullRequests.count
            return narrows || choice == selected ? Option(choice: choice, count: count) : nil
        }
        totalCount = pullRequests.count
        self.selected = selected
    }

    /// A filter has nothing to tell apart when every PR is the same thing (the merged list, or a list of PRs with no
    /// recorded state), so the picker stays out of the way until there are two kinds of PR.
    /// An active filter is always offered, since the picker is also how it is removed.
    var isOffered: Bool { selected != nil || options.count >= 2 }

    static func apply(_ choice: Choice?, to pullRequests: [PullRequest], funnel members: FunnelMembers = [:]) -> [PullRequest] {
        choice.map { choice in pullRequests.filter { choice.matches($0, funnel: members) } } ?? pullRequests
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
        picker.toolTip = "Filter this list by status, review, or merge funnel"
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
            // Review and checks are different questions from state, so each group gets a rule above it, as does the
            // first state after the funnel parts.
            let leavesFunnel = previous?.funnelPart != nil && option.choice.funnelPart == nil
            if leavesFunnel || option.choice.startsGroup && !Self.sameGroup(previous, option.choice) {
                picker.menu?.addItem(.separator())
            }
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
