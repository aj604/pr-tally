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
            HStack(spacing: 4) {
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
        }
        .menuBarExtraStyle(.window)
    }
}
