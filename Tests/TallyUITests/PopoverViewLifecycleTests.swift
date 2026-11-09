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

    /// `MenuBarExtra` sizes its window to the view, so the view's own width is the popover's.
    @Test func onlyThePullRequestListWidensThePopover() async {
        let now = Date()
        let pr = PullRequest(
            id: "1", title: "Fix crash when the token is missing", url: URL(string: "https://example.test/1")!,
            createdAt: now, mergedAt: nil, repository: .init(nameWithOwner: "me/app")
        )
        let store = TallyStore(defaults: UserDefaults(suiteName: "PopoverViewLifecycleTests-\(UUID().uuidString)")!) {
            MonthSnapshot(
                login: "me", window: MonthWindow(containing: now), opened: [pr], merged: [], totalContributions: 0,
                fetchedAt: now
            )
        }
        let host = NSHostingView(rootView: PopoverView(store: store))
        // The view picks up a change of screen on its next update, a turn or two later.
        func width(on screen: TallyStore.Screen) async -> CGFloat {
            store.screen = screen
            for _ in 0..<5 { await Task.yield() }
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        // Before the numbers arrive the list's screen has nothing to list, so it keeps the summary's width.
        #expect(await width(on: .pullRequests) == 320)

        await store.refresh()
        #expect(await width(on: .summary) == 320)
        #expect(await width(on: .pullRequests) == 400)
        #expect(await width(on: .settings) == 320)
    }
}
