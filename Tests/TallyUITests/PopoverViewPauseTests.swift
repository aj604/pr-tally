import AppKit
import SwiftUI
import Testing
import TallyCore
@testable import TallyUI

@MainActor @Suite(.serialized) struct PopoverViewPauseTests {
    @Test(arguments: [false, true])
    func pausedWithoutCurrentNumbersExplainsHowToGetThem(lastMonth: Bool) async throws {
        let suite = "PopoverViewPauseTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let oldDate = MonthWindow(containing: now).start.addingTimeInterval(-1)
        let old = MonthSnapshot(
            login: "fixture", window: MonthWindow(containing: oldDate), opened: [], merged: [],
            totalContributions: 0, fetchedAt: oldDate
        )
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("popover-pause-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cache = SnapshotCache(url: cacheURL)
        if lastMonth { cache.save(old) }
        let store = TallyStore(defaults: defaults, cache: cache) { throw CancellationError() }
        store.automaticRefreshPaused = true
        let (host, window) = await hosted(store)
        defer { window.orderOut(nil) }
        let labels = text(in: host)
        #expect(labels.contains("Automatic refresh paused"))
        #expect(labels.contains("Refresh now to count this month's PRs, or resume automatic refresh in Settings."))
        #expect(!labels.contains { $0.contains("Counting your PRs") || $0.hasPrefix("Waiting for") })
        if lastMonth { #expect(labels.contains { $0.hasPrefix("Last count for") }) }
        #expect(store.automaticRefreshPaused)
        #expect(!store.isRefreshing)
        #expect(store.errorMessage == nil)
    }

    @Test func manualRefreshReplacesThePausedPlaceholderWithProgressAndNumbers() async throws {
        let suite = "PopoverViewPauseTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pending = PendingRefresh()
        let now = Date()
        let snapshot = MonthSnapshot(
            login: "fixture", window: MonthWindow(containing: now), opened: [], merged: [],
            totalContributions: 0, fetchedAt: now
        )
        let store = TallyStore(defaults: defaults) { await pending.fetch() }
        store.automaticRefreshPaused = true
        let (host, window) = await hosted(store)
        defer { window.orderOut(nil); Task { await pending.finish(snapshot) } }
        let refresh = try #require(accessibilityTree(host).first { $0.accessibilityLabel?() == "Refresh now" })
        _ = refresh.accessibilityPerformPress?()
        for _ in 0..<100 where !store.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.isRefreshing)
        await settle(host)
        #expect(text(in: host).contains("Counting your PRs…"))
        #expect(!text(in: host).contains("Refresh now to count this month's PRs, or resume automatic refresh in Settings."))

        await pending.finish(snapshot)
        for _ in 0..<100 where store.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        await settle(host)
        #expect(store.snapshot == snapshot)
        #expect(store.automaticRefreshPaused)
        #expect(!text(in: host).contains("Counting your PRs…"))
        #expect(!text(in: host).contains("Refresh now to count this month's PRs, or resume automatic refresh in Settings."))
    }

    private func hosted(_ store: TallyStore) async -> (NSHostingView<PopoverView>, NSWindow) {
        NSApplication.shared.perform(
            NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
            with: "AXEnhancedUserInterface"
        )
        let host = NSHostingView(rootView: PopoverView(store: store))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        await settle(host)
        return (host, window)
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<10 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
    }

    private func text(in host: NSView) -> [String] {
        accessibilityTree(host).flatMap { node in
            let label = node.accessibilityLabel?()
            let selector = NSSelectorFromString("accessibilityValue")
            let element = node as? NSObject
            let value = element?.responds(to: selector) == true
                ? element?.perform(selector)?.takeUnretainedValue() as? String : nil
            return [label, value].compactMap { $0 }
        }
    }

    private func accessibilityTree(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 20 else { return [] }
        return [node] + (node.accessibilityChildren?() ?? []).flatMap {
            accessibilityTree($0 as AnyObject, depth: depth + 1)
        }
    }
}

private actor PendingRefresh {
    private var continuation: CheckedContinuation<MonthSnapshot, Never>?
    private var result: MonthSnapshot?

    func fetch() async -> MonthSnapshot {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ snapshot: MonthSnapshot) {
        result = snapshot
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}
