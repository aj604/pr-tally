import AppKit
import SwiftUI
import TallyCore

/// A separate action beside the GitHub link, so copying never opens the browser.
struct PullRequestWorkspaceCopyLinkButton: NSViewRepresentable {
    let pullRequest: PullRequest
    let pasteboard: NSPasteboard

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.copyLink(_:))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.url = pullRequest.url
        context.coordinator.pasteboard = pasteboard
        button.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        button.toolTip = "Copy link"
        button.setAccessibilityLabel("Copy link: \(pullRequest.title), \(pullRequest.repository.nameWithOwner)")
        button.cell?.setAccessibilityLabel(button.accessibilityLabel())
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: pullRequest.url, pasteboard: pasteboard) }

    @MainActor final class Coordinator: NSObject {
        var url: URL
        var pasteboard: NSPasteboard

        init(url: URL, pasteboard: NSPasteboard) {
            self.url = url
            self.pasteboard = pasteboard
        }

        @objc func copyLink(_ sender: NSButton) {
            pasteboard.clearContents()
            if pasteboard.setString(url.absoluteString, forType: .string) {
                sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
                sender.toolTip = "Link copied"
            }
        }
    }
}
