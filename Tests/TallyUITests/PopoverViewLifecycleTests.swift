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

    /// SwiftUI cancels a view's `.task` when its content goes away, which a busy month's fetch easily outlasts.
    @Test func closingThePopoverMidRefreshStillFinishesTheRefresh() async throws {
        let now = Date()
        let store = TallyStore(defaults: UserDefaults(suiteName: "PopoverViewLifecycleTests-\(UUID().uuidString)")!) {
            try await Task.sleep(for: .milliseconds(300))
            return MonthSnapshot(
                login: "me", window: MonthWindow(containing: now), opened: [], merged: [], totalContributions: 0,
                fetchedAt: now
            )
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PopoverView(store: store))
        window.orderFront(nil)
        for _ in 0..<200 where !store.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.isRefreshing)

        window.contentView = NSView()
        for _ in 0..<400 where store.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.errorMessage == nil)
        #expect(store.snapshot != nil)
        window.orderOut(nil)
    }
}
