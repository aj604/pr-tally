import AppKit
import SwiftUI
import Testing
import TallyCore
@testable import TallyUI

@MainActor @Suite(.serialized) struct PullRequestWorkspaceCopyLinksTests {
    private let now = Date(timeIntervalSince1970: 1_794_492_000)

    private func pr(
        _ id: String, repository: String = "me/app", hoursAgo: Double = 1, merged: Date? = nil
    ) -> PullRequest {
        PullRequest(
            id: id, title: "Work \(id)", url: URL(string: "https://github.com/\(repository)/pull/\(id)")!,
            createdAt: now.addingTimeInterval(-hoursAgo * 3600), mergedAt: merged,
            repository: .init(nameWithOwner: repository)
        )
    }

    private func snapshot() -> MonthSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let opened = [pr("11", hoursAgo: 2), pr("22", repository: "acme/infra"), pr("33", hoursAgo: 48)]
        return MonthSnapshot(
            login: "fixture", window: MonthWindow(containing: now, calendar: calendar), opened: opened,
            merged: [pr("44", hoursAgo: 40 * 24, merged: now)], totalContributions: 0, fetchedAt: now
        )
    }

    @Test func listOffersCopyLinksBesideTheCount() async throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let (host, window) = await hosted(pasteboard: pasteboard)
        defer { window.orderOut(nil) }
        let buttons = descendants(of: host).compactMap { $0 as? NSButton }
        print("List copy action labels: \(buttons.compactMap { $0.accessibilityLabel() }.sorted())")
        let button = try #require(buttons.first { $0.title == "Copy links" })
        #expect(button.isEnabled)
        #expect(button.accessibilityLabel() == "Copy links for 2 PRs in this list")
        let frame = host.convert(button.bounds, from: button)
        #expect(frame.minX >= 0 && frame.maxX <= 288 && frame.height > 0)
    }

    @Test func copyingTheListReplacesThePasteboardInVisibleOrder() async throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let (host, window) = await hosted(pasteboard: pasteboard)
        defer { window.orderOut(nil) }
        pasteboard.setString("Previously copied text", forType: .string)
        let button = try copyButton(in: host)
        button.sendAction(button.action, to: button.target)
        #expect(pasteboard.string(forType: .string) == "https://github.com/acme/infra/pull/22\nhttps://github.com/me/app/pull/11")
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(button.title == "Links copied")
        #expect(button.toolTip == "2 links copied")
    }

    @Test func repositorySearchAndScopeChangesUpdateTheCopiedSet() async throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let (host, window) = await hosted(pasteboard: pasteboard)
        defer { window.orderOut(nil) }
        let picker = try #require(descendants(of: host).compactMap { $0 as? NSPopUpButton }.first)
        let field = try #require(descendants(of: host).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "Search title, repo, # or URL"
        })
        let scope = try #require(descendants(of: host).compactMap { $0 as? NSSegmentedControl }.first)

        picker.selectItem(withTitle: "me/app (1)")
        picker.sendAction(picker.action, to: picker.target)
        await settle(host)
        try expectCopied("https://github.com/me/app/pull/11", in: host, pasteboard: pasteboard)

        scope.selectedSegment = 1
        scope.sendAction(scope.action, to: scope.target)
        await settle(host)
        try expectCopied("https://github.com/me/app/pull/11\nhttps://github.com/me/app/pull/33", in: host, pasteboard: pasteboard)

        field.stringValue = "33"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        await settle(host)
        #expect(try copyButton(in: host).title == "Copy links")
        try expectCopied("https://github.com/me/app/pull/33", in: host, pasteboard: pasteboard)

        field.stringValue = ""
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        picker.selectItem(at: 0)
        picker.sendAction(picker.action, to: picker.target)
        await settle(host)
        try expectCopied(
            "https://github.com/acme/infra/pull/22\nhttps://github.com/me/app/pull/11\nhttps://github.com/me/app/pull/33",
            in: host, pasteboard: pasteboard
        )
    }

    @Test func pickedDayAndMergedFunnelCopyOnlyTheirRows() async throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let day = snapshot().window.dayIndex(of: now.addingTimeInterval(-48 * 3600))!
        for (focus, id) in [(PullRequestFocus(day: day), "33"), (.init(funnel: .carriedIn), "44")] {
            let (host, window) = await hosted(focus: focus, pasteboard: pasteboard)
            defer { window.orderOut(nil) }
            try expectCopied("https://github.com/me/app/pull/\(id)", in: host, pasteboard: pasteboard)
            #expect(try copyButton(in: host).title == "Link copied")
        }
    }

    @Test func anEmptySearchDisablesCopyingAndPreservesThePasteboard() async throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let (host, window) = await hosted(pasteboard: pasteboard)
        defer { window.orderOut(nil) }
        let field = try #require(descendants(of: host).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "Search title, repo, # or URL"
        })
        field.stringValue = "no matches"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        await settle(host)
        let button = try copyButton(in: host)
        #expect(!button.isEnabled)
        #expect(button.accessibilityLabel() == "Copy links for 0 PRs in this list")
        pasteboard.setString("Keep this", forType: .string)
        // Even an explicit action dispatch must not erase the clipboard for an empty list.
        button.sendAction(button.action, to: button.target)
        #expect(pasteboard.string(forType: .string) == "Keep this")
    }

    @Test func aReusedActionCopiesUpdatedURLsVerbatimAndLabelsItsCell() async throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let host = NSHostingView(rootView: PullRequestWorkspaceCopyLinksButton(
            pullRequests: [pr("11"), pr("22")], pasteboard: pasteboard
        ))
        host.frame = NSRect(x: 0, y: 0, width: 110, height: 24)
        await settle(host)
        try expectCopied("https://github.com/me/app/pull/11\nhttps://github.com/me/app/pull/22", in: host, pasteboard: pasteboard)

        let url = URL(string: "https://git.example.test/enterprise/project/pull/22?diff=split#discussion")!
        let updated = PullRequest(
            id: "other", title: "Updated work", url: url, createdAt: now, mergedAt: nil,
            repository: .init(nameWithOwner: "enterprise/project")
        )
        host.rootView = PullRequestWorkspaceCopyLinksButton(pullRequests: [updated], pasteboard: pasteboard)
        await settle(host)
        let button = try copyButton(in: host)
        #expect(button.title == "Copy links")
        #expect(button.cell?.accessibilityLabel() == "Copy links for 1 PR in this list")
        try expectCopied(url.absoluteString, in: host, pasteboard: pasteboard)
        #expect(button.cell?.accessibilityLabel() == "Copy links for 1 PR in this list")
    }

    @Test func aScrollingListCopiesEveryRowIncludingThoseOffscreen() async throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let prs = (1...30).map { pr("\($0)", hoursAgo: Double($0) / 100) }
        let fixture = MonthSnapshot(
            login: "fixture", window: snapshot().window, opened: Array(prs.reversed()), merged: [],
            totalContributions: 0, fetchedAt: now
        )
        let (host, window) = await hosted(pasteboard: pasteboard, fixture: fixture)
        defer { window.orderOut(nil) }
        let button = try copyButton(in: host)
        #expect(button.accessibilityLabel() == "Copy links for 30 PRs in this list")
        try expectCopied(prs.map { $0.url.absoluteString }.joined(separator: "\n"), in: host, pasteboard: pasteboard)
        #expect(button.toolTip == "30 links copied")
    }

    private func copyButton(in host: NSView) throws -> NSButton {
        try #require(descendants(of: host).compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel()?.hasPrefix("Copy links for") == true
        })
    }

    private func expectCopied(_ text: String, in host: NSView, pasteboard: NSPasteboard) throws {
        let button = try copyButton(in: host)
        button.sendAction(button.action, to: button.target)
        #expect(pasteboard.string(forType: .string) == text)
    }

    private func hosted(
        focus: PullRequestFocus = .init(), pasteboard: NSPasteboard, fixture: MonthSnapshot? = nil
    ) async -> (NSHostingView<PullRequestList>, NSWindow) {
        let host = NSHostingView(rootView: PullRequestList(
            snapshot: fixture ?? snapshot(), metric: .opened, now: now, focus: focus, copyLinkPasteboard: pasteboard
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
        NSPasteboard(name: .init("pr-workspace-r4-\(UUID().uuidString)"))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
