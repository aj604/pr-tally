import AppKit
import SwiftUI
import Testing
import TallyCore
@testable import TallyUI

@MainActor @Suite struct PullRequestWorkspaceCopyLinkTests {
    private let now = Date(timeIntervalSince1970: 1_794_492_000)

    private func pr(_ id: String, repository: String = "me/app") -> PullRequest {
        PullRequest(
            id: id, title: "Work \(id)", url: URL(string: "https://github.com/\(repository)/pull/\(id)")!,
            createdAt: now.addingTimeInterval(-3600), mergedAt: nil, repository: .init(nameWithOwner: repository)
        )
    }

    private func snapshot() -> MonthSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return MonthSnapshot(
            login: "fixture", window: MonthWindow(containing: now, calendar: calendar),
            opened: [pr("11"), pr("22", repository: "acme/infra")], merged: [],
            totalContributions: 0, fetchedAt: now
        )
    }

    @Test func everyVisibleRowOffersItsOwnCopyLinkAction() async {
        let host = NSHostingView(rootView: PullRequestList(snapshot: snapshot(), metric: .opened, now: now))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 288, height: 420), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<5 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
        let labels = descendants(of: host).compactMap { ($0 as? NSButton)?.accessibilityLabel() }
            .filter { $0.hasPrefix("Copy link:") }
        print("Visible copy actions: \(labels.sorted())")
        #expect(labels.sorted() == ["Copy link: Work 11, me/app", "Copy link: Work 22, acme/infra"])
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
