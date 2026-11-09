import AppKit
import SwiftUI
import Testing
import TallyCore
@testable import TallyUI

@MainActor @Suite(.serialized) struct PullRequestWorkspaceMetricTests {
    private let now = Date(timeIntervalSince1970: 1_794_492_000)  // Nov 12, 2026, 14:00 UTC

    private func pr(
        _ id: String, repository: String = "me/app", hoursAgo: Double = 1, merged: Date? = nil
    ) -> PullRequest {
        PullRequest(
            id: id, title: "Work \(id)", url: URL(string: "https://github.com/\(repository)/pull/\(id)")!,
            createdAt: now.addingTimeInterval(-hoursAgo * 3600), mergedAt: merged,
            repository: .init(nameWithOwner: repository)
        )
    }

    /// Today: four opened (one already merged) and two merged, one of them opened last month.
    private func snapshot() -> MonthSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let mergedToday = pr("3", hoursAgo: 5, merged: now.addingTimeInterval(-1800))
        let carriedIn = pr("4", repository: "acme/infra", hoursAgo: 40 * 24, merged: now.addingTimeInterval(-3 * 3600))
        return MonthSnapshot(
            login: "fixture", window: MonthWindow(containing: now, calendar: calendar),
            opened: [pr("1"), pr("2", repository: "acme/infra", hoursAgo: 2), mergedToday, pr("5", hoursAgo: 3)],
            merged: [mergedToday, carriedIn], totalContributions: 0, fetchedAt: now
        )
    }

    @Test func optionsNameEachMetricWithItsCount() {
        let metrics = PullRequestWorkspaceMetric { $0 == .opened ? 4 : 1 }
        #expect(metrics.options.map(\.title) == ["Opened (4)", "Merged (1)"])
    }

    @Test func switchingKeepsOnlyAFunnelPartTheNewMetricCounts() {
        #expect(PullRequestWorkspaceMetric.funnel(.notMerged, keptFor: .opened) == .notMerged)
        #expect(PullRequestWorkspaceMetric.funnel(.notMerged, keptFor: .merged) == nil)
        #expect(PullRequestWorkspaceMetric.funnel(.carriedIn, keptFor: .merged) == .carriedIn)
        #expect(PullRequestWorkspaceMetric.funnel(.carriedIn, keptFor: .opened) == nil)
        #expect(PullRequestWorkspaceMetric.funnel(nil, keptFor: .opened) == nil)
    }

    @Test func pickerNamesTheShowingMetricAndCountsBoth() async throws {
        let (host, window) = await hosted()
        defer { window.orderOut(nil) }
        let picker = try metricPicker(in: host)
        #expect(picker.pullsDown)
        #expect(picker.itemTitles == ["Opened", "Opened (4)", "Merged (2)"])
        #expect(picker.item(withTitle: "Opened (4)")?.state == .on)
        #expect(picker.item(withTitle: "Merged (2)")?.state == .off)
        #expect(picker.toolTip == "Show the PRs opened or the PRs merged")
        let frame = host.convert(picker.bounds, from: picker)
        #expect(frame.minX >= 0 && frame.maxX <= 288 && frame.height > 0)
    }

    @Test func switchingListsTheOtherMetricAndKeepsTheSearch() async throws {
        let (host, window) = await hosted()
        defer { window.orderOut(nil) }
        let field = try searchField(in: host)
        field.stringValue = "Work"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        await settle(host)

        try select("Merged (2)", in: metricPicker(in: host))
        await settle(host)
        #expect(try metricPicker(in: host).itemTitles == ["Merged", "Opened (4)", "Merged (2)"])
        #expect(field.placeholderString == "Search 2 PRs merged")
        #expect(field.stringValue == "Work")
        #expect(try repositoryPicker(in: host).itemTitles == ["All repositories (2)", "acme/infra (1)", "me/app (1)"])

        try select("Opened (4)", in: metricPicker(in: host))
        await settle(host)
        #expect(field.placeholderString == "Search 4 PRs opened")
    }

    @Test func countsAndSwitchingFollowTheRepository() async throws {
        let (host, window) = await hosted(focus: .init(repository: "me/app"))
        defer { window.orderOut(nil) }
        #expect(try metricPicker(in: host).itemTitles == ["Opened", "Opened (3)", "Merged (1)"])
        try select("Merged (1)", in: metricPicker(in: host))
        await settle(host)
        #expect(try repositoryPicker(in: host).titleOfSelectedItem == "me/app (1)")
        #expect(try searchField(in: host).placeholderString == "Search 1 PR merged")
    }

    @Test func switchingAwayFromAFunnelPartDropsIt() async throws {
        let (host, window) = await hosted(focus: .init(funnel: .notMerged))
        defer { window.orderOut(nil) }
        // The merged count is what the merged list will hold once the opened-only part is dropped.
        #expect(try metricPicker(in: host).itemTitles == ["Opened", "Opened (3)", "Merged (2)"])
        try select("Merged (2)", in: metricPicker(in: host))
        await settle(host)
        #expect(try searchField(in: host).placeholderString == "Search 2 PRs merged")
        // Back on opened, the part stays dropped, so the list holds every PR opened today.
        try select("Opened (4)", in: metricPicker(in: host))
        await settle(host)
        #expect(try searchField(in: host).placeholderString == "Search 4 PRs opened")
    }

    @Test func aCarriedInListCountsTheOpenedListWithoutThePart() async throws {
        let (host, window) = await hosted(focus: .init(funnel: .carriedIn))
        defer { window.orderOut(nil) }
        #expect(try metricPicker(in: host).itemTitles == ["Merged", "Opened (4)", "Merged (1)"])
        #expect(try searchField(in: host).placeholderString == "Search 1 PR merged")
    }

    private func hosted(focus: PullRequestFocus = .init()) async -> (NSHostingView<PullRequestList>, NSWindow) {
        let host = NSHostingView(rootView: PullRequestList(snapshot: snapshot(), metric: .opened, now: now, focus: focus))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 288, height: 420), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        await settle(host)
        return (host, window)
    }

    private func metricPicker(in host: NSView) throws -> NSPopUpButton {
        try #require(descendants(of: host).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "Opened or merged"
        })
    }

    private func repositoryPicker(in host: NSView) throws -> NSPopUpButton {
        try #require(descendants(of: host).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "Repository"
        })
    }

    private func searchField(in host: NSView) throws -> NSTextField {
        try #require(descendants(of: host).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString?.hasPrefix("Search ") == true
        })
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<5 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
    }

    private func select(_ title: String, in picker: NSPopUpButton) {
        picker.selectItem(withTitle: title)
        picker.sendAction(picker.action, to: picker.target)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
