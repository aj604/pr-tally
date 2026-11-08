import AppKit
import SwiftUI
import TallyCore

/// Repository choices from the current metric, day and funnel, before repository or text filtering.
struct PullRequestWorkspaceRepositories {
    struct Option: Identifiable, Equatable {
        let name: String
        let count: Int
        var id: String { name }
    }

    let options: [Option]
    let totalCount: Int

    init(_ pullRequests: [PullRequest], selected: String? = nil) {
        var counts = Dictionary(grouping: pullRequests, by: \.repository.nameWithOwner).mapValues(\.count)
        // Keep the selection visible and removable when a different day has no PRs in this repository.
        if let selected, counts[selected] == nil { counts[selected] = 0 }
        options = counts.map { Option(name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
        totalCount = pullRequests.count
    }
}

/// A native menu keeps full repository names available while its closed title fits the narrow popover.
struct PullRequestWorkspaceRepositoryPicker: NSViewRepresentable {
    let repositories: PullRequestWorkspaceRepositories
    @Binding var selection: String?

    func makeNSView(context: Context) -> NSPopUpButton {
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.cell?.lineBreakMode = .byTruncatingMiddle
        picker.setAccessibilityLabel("Repository")
        picker.toolTip = "Filter this list by repository"
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.selectRepository(_:))
        return picker
    }

    func updateNSView(_ picker: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        picker.removeAllItems()
        picker.addItem(withTitle: "All repositories (\(repositories.totalCount.formatted()))")
        for option in repositories.options {
            picker.addItem(withTitle: "\(option.name) (\(option.count.formatted()))")
            picker.lastItem?.representedObject = option.name
        }
        let index = repositories.options.firstIndex { $0.name == selection }.map { $0 + 1 } ?? 0
        picker.selectItem(at: index)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<String?>

        init(selection: Binding<String?>) { self.selection = selection }

        @objc func selectRepository(_ sender: NSPopUpButton) {
            selection.wrappedValue = sender.selectedItem?.representedObject as? String
        }
    }
}
