import AppKit
import SwiftUI
import Testing
import TallyCore
@testable import TallyUI

@MainActor @Suite(.serialized) struct PopoverViewLifecycleTests {
    private func store() -> TallyStore {
        TallyStore(defaults: UserDefaults(suiteName: "PopoverViewLifecycleTests-\(UUID().uuidString)")!) { throw CancellationError() }
    }

    @Test func theStoreOpensAtTheNumbersAndGoesBackThereWhenTheyAreClosed() {
        let store = store()
        #expect(store.screen == .summary)
        for screen in [TallyStore.Screen.pullRequests, .settings] {
            store.screen = screen
            store.popoverClosed()
            #expect(store.screen == .summary)
        }
    }

    /// `MenuBarExtra` removes the view's content when its window closes, and that is what the view listens for.
    @Test func closingThePopoverWindowReturnsToTheNumbers() async {
        let store = store()
        store.screen = .pullRequests
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PopoverView(store: store))
        window.orderFront(nil)
        for _ in 0..<5 { await Task.yield() }
        #expect(store.screen == .pullRequests)

        window.contentView = NSView()
        for _ in 0..<5 { await Task.yield() }
        #expect(store.screen == .summary)
        window.orderOut(nil)
    }
}
