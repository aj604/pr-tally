import AppKit
import SwiftUI
import TallyCore

/// Copies the list as shown, for pasting a day's work or a filtered set of PRs into a conversation.
struct PullRequestWorkspaceCopyLinksButton: NSViewRepresentable {
    let pullRequests: [PullRequest]
    let pasteboard: NSPasteboard

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Copy links", target: context.coordinator, action: #selector(Coordinator.copyLinks(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.urls = pullRequests.map(\.url)
        context.coordinator.pasteboard = pasteboard
        button.title = "Copy links"
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
                sender.title = urls.count == 1 ? "Link copied" : "Links copied"
                sender.toolTip = "\(urls.count.formatted()) \(urls.count == 1 ? "link" : "links") copied"
            }
        }
    }
}
