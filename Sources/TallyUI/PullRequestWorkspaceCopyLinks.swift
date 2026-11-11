import AppKit
import SwiftUI
import TallyCore

/// Copies the list as shown, for pasting a day's work or a filtered set of PRs into a conversation.
struct PullRequestWorkspaceCopyLinksButton: NSViewRepresentable {
    let pullRequests: [PullRequest]
    let pasteboard: NSPasteboard

    /// An icon like each row's copy button, so it fits at the end of the search row; the tooltip and accessibility
    /// label say how many links it copies.
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.copyLinks(_:))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.urls = pullRequests.map(\.url)
        context.coordinator.pasteboard = pasteboard
        button.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: nil)
        button.isEnabled = !pullRequests.isEmpty
        let count = pullRequests.count.formatted()
        let noun = pullRequests.count == 1 ? "PR" : "PRs"
        button.toolTip = "Copy links for \(count) \(noun) in this list, one per line"
        button.setAccessibilityLabel("Copy links for \(count) \(noun) in this list")
        button.cell?.setAccessibilityLabel(button.accessibilityLabel())
    }

    func makeCoordinator() -> Coordinator { Coordinator(urls: pullRequests.map(\.url), pasteboard: pasteboard) }

    @MainActor final class Coordinator: NSObject {
        var urls: [URL]
        var pasteboard: NSPasteboard

        init(urls: [URL], pasteboard: NSPasteboard) {
            self.urls = urls
            self.pasteboard = pasteboard
        }

        @objc func copyLinks(_ sender: NSButton) {
            guard !urls.isEmpty else { return }
            pasteboard.clearContents()
            if pasteboard.setString(urls.map(\.absoluteString).joined(separator: "\n"), forType: .string) {
                sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
                sender.toolTip = "\(urls.count.formatted()) \(urls.count == 1 ? "link" : "links") copied"
            }
        }
    }
}
