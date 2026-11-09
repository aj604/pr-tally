import AppKit
import SwiftUI
import Testing
import TallyCore
@testable import TallyUI

@MainActor @Suite(.serialized) struct PullRequestWorkspaceSortTests {
    private let now = Date(timeIntervalSince1970: 1_794_492_000)

    private func pr(_ id: String, openedHoursAgo: Double, mergedAfterHours: Double? = nil) -> PullRequest {
        let opened = now.addingTimeInterval(-openedHoursAgo * 3_600)
        return PullRequest(
            id: id, title: "Work \(id)", url: URL(string: "https://github.com/me/app/pull/\(id)")!, createdAt: opened,
            mergedAt: mergedAfterHours.map { opened.addingTimeInterval($0 * 3_600) }, repository: .init(nameWithOwner: "me/app")
        )
    }

    /// Newest first, as the list hands them over: one still open, then merged in 30 minutes, 2 days and 1 hour.
    private var newestFirst: [PullRequest] {
        [
            pr("1", openedHoursAgo: 1), pr("2", openedHoursAgo: 10, mergedAfterHours: 0.5),
            pr("3", openedHoursAgo: 72, mergedAfterHours: 48), pr("4", openedHoursAgo: 120, mergedAfterHours: 1),
        ]
    }

    @Test func newestFirstKeepsTheListsOrder() {
        #expect(PullRequestWorkspaceSort.newest.apply(to: newestFirst).map(\.id) == ["1", "2", "3", "4"])
    }

    @Test func slowestToMergeRanksMergedPullRequestsByTheirTimeAndLeavesUnmergedOnesBelow() {
        #expect(PullRequestWorkspaceSort.slowestToMerge.apply(to: newestFirst).map(\.id) == ["3", "4", "2", "1"])
    }

    @Test func slowestToMergeRanksTheExactTimeNotTheRoundedOne() {
        // Both read "Merged in 5h"; the one that took longer still ranks first.
        let prs = [pr("1", openedHoursAgo: 10, mergedAfterHours: 4.6), pr("2", openedHoursAgo: 20, mergedAfterHours: 5.4)]
        #expect(PullRequestWorkspaceSort.slowestToMerge.apply(to: prs).map(\.id) == ["2", "1"])
    }

    @Test func pullRequestsThatTookTheSameTimeKeepTheirNewestFirstOrder() {
        let prs = [
            pr("1", openedHoursAgo: 2), pr("2", openedHoursAgo: 10, mergedAfterHours: 1),
            pr("3", openedHoursAgo: 20, mergedAfterHours: 1), pr("4", openedHoursAgo: 30),
        ]
        #expect(PullRequestWorkspaceSort.slowestToMerge.apply(to: prs).map(\.id) == ["2", "3", "1", "4"])
    }

    @Test func isOfferedOnceTwoPullRequestsHaveMergedOrWhileChosen() {
        let oneMerged = Array(newestFirst.prefix(2))
        #expect(!PullRequestWorkspaceSort.isOffered(.newest, for: oneMerged))
        #expect(PullRequestWorkspaceSort.isOffered(.newest, for: Array(newestFirst.prefix(3))))
        #expect(PullRequestWorkspaceSort.isOffered(.slowestToMerge, for: oneMerged))
        #expect(PullRequestWorkspaceSort.isOffered(.slowestToMerge, for: []))
    }

    @Test func onlyNewestFirstSplitsTheMonthIntoDays() {
        #expect(PullRequestWorkspaceSort.newest.groupsByDay)
        #expect(!PullRequestWorkspaceSort.slowestToMerge.groupsByDay)
    }

    @Test func aRowCarriesItsDayWhenTheMonthListsWithoutSections() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let window = MonthWindow(containing: now, calendar: calendar)
        let day = window.dayTitle(window.dayIndex(of: now)!)
        #expect(window.rowTime(now, withDay: true) == "\(day), \(window.rowTime(now))")
        #expect(!window.rowTime(now).contains(day))
    }

    @Test func theListOffersTheSortMenuOnlyOnceTwoPullRequestsHaveMerged() async throws {
        let (few, fewWindow) = await hosted(Array(newestFirst.prefix(2)), pasteboard: privatePasteboard())
        defer { fewWindow.orderOut(nil) }
        #expect(sortPicker(in: few) == nil)

        let (host, window) = await hosted(newestFirst, pasteboard: privatePasteboard())
        defer { window.orderOut(nil) }
        let picker = try #require(sortPicker(in: host))
        #expect(picker.itemTitles == ["", "Newest first", "Slowest to merge"])
        #expect(picker.item(withTitle: "Newest first")?.state == .on)
        #expect(picker.toolTip == "Sort this list: Newest first")
        let frame = host.convert(picker.bounds, from: picker)
        #expect(frame.minX >= 0 && frame.maxX <= 288 && frame.height > 0)
    }

    @Test func choosingSlowestToMergeReordersTheListAndWhatItCopies() async throws {
        let pasteboard = privatePasteboard()
        let (host, window) = await hosted(newestFirst, pasteboard: pasteboard)
        defer { window.orderOut(nil) }
        try expectCopied(["1", "2", "3", "4"], in: host, pasteboard: pasteboard)

        let picker = try #require(sortPicker(in: host))
        picker.selectItem(withTitle: "Slowest to merge")
        picker.sendAction(picker.action, to: picker.target)
        await settle(host)
        #expect(try #require(sortPicker(in: host)).item(withTitle: "Slowest to merge")?.state == .on)
        #expect(try #require(sortPicker(in: host)).accessibilityValue() as? String == "Slowest to merge")
        try expectCopied(["3", "4", "2", "1"], in: host, pasteboard: pasteboard)
    }

    private func expectCopied(_ ids: [String], in host: NSView, pasteboard: NSPasteboard) throws {
        let button = try #require(descendants(of: host).compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel()?.hasPrefix("Copy links for") == true
        })
        button.sendAction(button.action, to: button.target)
        #expect(pasteboard.string(forType: .string) == ids.map { "https://github.com/me/app/pull/\($0)" }.joined(separator: "\n"))
    }

    private func sortPicker(in host: NSView) -> NSPopUpButton? {
        descendants(of: host).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Sort" }
    }

    /// Opened on the repository, so the list shows the whole month.
    private func hosted(_ prs: [PullRequest], pasteboard: NSPasteboard) async -> (NSHostingView<PullRequestList>, NSWindow) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let snapshot = MonthSnapshot(
            login: "fixture", window: MonthWindow(containing: now, calendar: calendar), opened: prs,
            merged: prs.filter { $0.mergedAt != nil }, totalContributions: 0, fetchedAt: now
        )
        let host = NSHostingView(rootView: PullRequestList(
            snapshot: snapshot, metric: .opened, now: now, focus: .init(repository: "me/app"), copyLinkPasteboard: pasteboard
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 288, height: 420), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        await settle(host)
        return (host, window)
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<5 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
    }

    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("pr-workspace-r8-\(UUID().uuidString)"))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
