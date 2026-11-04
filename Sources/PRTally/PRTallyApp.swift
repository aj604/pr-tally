import SwiftUI
import TallyCore
import TallyUI

@main
struct PRTallyApp: App {
    @State private var store: TallyStore

    init() {
        let client = GitHubClient(tokens: TokenProvider(override: { KeychainToken.standard.read() }))
        let store = TallyStore { try await client.fetchSnapshot() }
        store.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            Text(store.menuBarTitle).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
