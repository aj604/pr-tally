import SwiftUI
import TallyCore
import TallyUI

@main
struct PRTallyApp: App {
    @State private var store: TallyStore

    init() {
        let client = GitHubClient(tokens: TokenProvider(override: { KeychainToken.standard.read() }))
        let store = TallyStore(cache: .standard, notify: { MilestoneNotifier.shared.post($0) }) {
            try await client.fetchSnapshot()
        }
        store.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            let title = store.menuBarTitle()
            let tooltip = store.menuBarTooltip()
            HStack(spacing: 4) {
                if store.automaticRefreshPaused {
                    Image(systemName: "pause.fill")
                }
                if store.menuBarIsStale {
                    Image(nsImage: MenuBarGlyph.fadedImage(for: store.pace(), title: title))
                } else if store.menuBarNumberIsGreen() {
                    Image(nsImage: MenuBarGlyph.image(for: store.pace(), greenTitle: title))
                } else {
                    Image(nsImage: MenuBarGlyph.image(for: store.pace()))
                    Text(title).monospacedDigit()
                }
            }
            .accessibilityLabel(store.menuBarAccessibilityLabel)
            // SwiftUI's `help` doesn't reach a menu bar item; the tip has to go on its status bar button.
            .task(id: tooltip) { Self.statusBarButton()?.toolTip = tooltip }
        }
        .menuBarExtraStyle(.window)
    }

    /// The menu bar item's button. `MenuBarExtra` doesn't expose it, but it's the app's only status item.
    @MainActor private static func statusBarButton() -> NSStatusBarButton? {
        func button(in view: NSView) -> NSStatusBarButton? {
            view as? NSStatusBarButton ?? view.subviews.lazy.compactMap(button(in:)).first
        }
        return NSApp.windows.lazy.compactMap { $0.contentView.flatMap(button(in:)) }.first
    }
}
