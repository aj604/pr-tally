import AppKit
import SwiftUI
import Testing
import TallyCore
@testable import TallyUI

@MainActor @Suite(.serialized) struct PullRequestWorkspaceCopyLinkTests {
    private let now = Date(timeIntervalSince1970: 1_794_492_000)

    private func pr(
        _ id: String, repository: String = "me/app", opened: Date? = nil, merged: Date? = nil, url: URL? = nil
    ) -> PullRequest {
        PullRequest(
            id: id, title: "Work \(id)", url: url ?? URL(string: "https://github.com/\(repository)/pull/\(id)")!,
            createdAt: opened ?? now.addingTimeInterval(-3600), mergedAt: merged,
            repository: .init(nameWithOwner: repository)
        )
    }

    private func snapshot() -> MonthSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return MonthSnapshot(
            login: "fixture", window: MonthWindow(containing: now, calendar: calendar),
            opened: [pr("11"), pr("22", repository: "acme/infra"), pr("33", opened: now.addingTimeInterval(-48 * 3600))],
            merged: [pr("44", opened: now.addingTimeInterval(-40 * 86_400), merged: now)],
            totalContributions: 0, fetchedAt: now
        )
    }

    @Test func everyVisibleRowOffersItsOwnCopyLinkAction() async {
        let (host, window) = await hosted()
        defer { window.orderOut(nil) }
        let labels = copyButtons(in: host).compactMap { $0.accessibilityLabel() }
        print("Visible copy actions: \(labels.sorted())")
        #expect(labels.sorted() == ["Copy link: Work 11, me/app", "Copy link: Work 22, acme/infra"])
        for button in copyButtons(in: host) {
            #expect(button.toolTip == "Copy link")
            #expect(button.frame.width == 24 && button.frame.height > 0)
            let frame = host.convert(button.bounds, from: button)
            #expect(frame.minX >= 0 && frame.maxX <= 288)
        }
    }

    @Test func exposedCopyActionsIdentifyTheRowBeforeAndAfterCopying() async throws {
        NSApplication.shared.perform(
            NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
            with: "AXEnhancedUserInterface"
        )
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let (host, window) = await hosted(pasteboard: pasteboard)
        defer { window.orderOut(nil) }
        for button in copyButtons(in: host) {
            let expected = try #require(button.accessibilityLabel())
            let cell = try #require(button.cell)
            let exposed = try #require(accessibilityDescendants(of: host).first { $0 === cell })
            #expect(exposed.accessibilityLabel?() == expected)
            copy(button)
            await settle(host)
            #expect(button.toolTip == "Link copied")
            let copied = try #require(accessibilityDescendants(of: host).first { $0 === cell })
            #expect(copied.accessibilityLabel?() == expected)
        }
    }

    @Test func copyingEachRowReplacesThePasteboardWithItsExactURL() async throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let (host, window) = await hosted(pasteboard: pasteboard)
        defer { window.orderOut(nil) }
        pasteboard.setString("Previously copied text", forType: .string)
        for (label, url) in [
            ("Copy link: Work 22, acme/infra", "https://github.com/acme/infra/pull/22"),
            ("Copy link: Work 11, me/app", "https://github.com/me/app/pull/11"),
        ] {
            let button = try #require(copyButtons(in: host).first { $0.accessibilityLabel() == label })
            copy(button)
            #expect(pasteboard.string(forType: .string) == url)
            #expect(pasteboard.pasteboardItems?.count == 1)
            #expect(button.toolTip == "Link copied")
        }
    }

    @Test func filteringAndClearingKeepCopyTargetsOnTheVisibleRows() async throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let (host, window) = await hosted(pasteboard: pasteboard)
        defer { window.orderOut(nil) }
        let picker = try #require(descendants(of: host).compactMap { $0 as? NSPopUpButton }.first)
        let field = try #require(descendants(of: host).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "Search title or repository"
        })
        picker.selectItem(withTitle: "me/app (1)")
        picker.sendAction(picker.action, to: picker.target)
        await settle(host)
        #expect(copyButtons(in: host).compactMap { $0.accessibilityLabel() } == ["Copy link: Work 11, me/app"])
        copy(try #require(copyButtons(in: host).first))
        #expect(pasteboard.string(forType: .string) == "https://github.com/me/app/pull/11")

        field.stringValue = "infra"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        await settle(host)
        #expect(copyButtons(in: host).isEmpty)
        picker.selectItem(at: 0)
        picker.sendAction(picker.action, to: picker.target)
        await settle(host)
        #expect(copyButtons(in: host).compactMap { $0.accessibilityLabel() } == ["Copy link: Work 22, acme/infra"])
        copy(try #require(copyButtons(in: host).first))
        #expect(pasteboard.string(forType: .string) == "https://github.com/acme/infra/pull/22")

        field.stringValue = ""
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        await settle(host)
        #expect(copyButtons(in: host).count == 2)
    }

    @Test func copyActionsFollowPickedDaysAndTheMergedFunnel() async throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let previousDay = snapshot().window.dayIndex(of: now.addingTimeInterval(-48 * 3600))!
        for (focus, id) in [(PullRequestFocus(day: previousDay), "33"), (.init(funnel: .carriedIn), "44")] {
            let (host, window) = await hosted(focus: focus, pasteboard: pasteboard)
            defer { window.orderOut(nil) }
            let buttons = copyButtons(in: host)
            #expect(buttons.compactMap { $0.accessibilityLabel() } == ["Copy link: Work \(id), me/app"])
            copy(try #require(buttons.first))
            #expect(pasteboard.string(forType: .string) == "https://github.com/me/app/pull/\(id)")
        }
    }

    @Test func aReusedButtonCopiesTheUpdatedURLVerbatim() async throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let host = NSHostingView(rootView: PullRequestWorkspaceCopyLinkButton(pullRequest: pr("11"), pasteboard: pasteboard))
        host.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        await settle(host)
        copy(try #require(descendants(of: host).compactMap { $0 as? NSButton }.first))
        #expect(pasteboard.string(forType: .string) == "https://github.com/me/app/pull/11")

        let url = URL(string: "https://git.example.test/enterprise/project/pull/22?diff=split#discussion")!
        host.rootView = PullRequestWorkspaceCopyLinkButton(pullRequest: pr("22", url: url), pasteboard: pasteboard)
        await settle(host)
        let updated = try #require(descendants(of: host).compactMap { $0 as? NSButton }.first)
        #expect(updated.toolTip == "Copy link")
        copy(updated)
        #expect(pasteboard.string(forType: .string) == url.absoluteString)
    }

    private func hosted(
        focus: PullRequestFocus = .init(), pasteboard: NSPasteboard? = nil
    ) async -> (NSHostingView<PullRequestList>, NSWindow) {
        let host = NSHostingView(rootView: PullRequestList(
            snapshot: snapshot(), metric: .opened, now: now, focus: focus, copyLinkPasteboard: pasteboard ?? .general
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 288, height: 420), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        await settle(host)
        return (host, window)
    }

    private func copy(_ button: NSButton) {
        button.sendAction(button.action, to: button.target)
    }

    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("pr-workspace-r3-\(UUID().uuidString)"))
    }

    private func copyButtons(in host: NSView) -> [NSButton] {
        descendants(of: host).compactMap { $0 as? NSButton }.filter {
            $0.accessibilityLabel()?.hasPrefix("Copy link:") == true
        }
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<5 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
    }

    private func accessibilityDescendants(of node: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 20 else { return [] }
        return [node] + (node.accessibilityChildren?() ?? []).flatMap {
            accessibilityDescendants(of: $0 as AnyObject, depth: depth + 1)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
