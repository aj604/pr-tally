import AppKit
import SwiftUI
import Testing
import TallyCore
@testable import TallyUI

@MainActor @Suite(.serialized) struct PullRequestWorkspaceIdentityTests {
    private let now = Date(timeIntervalSince1970: 1_794_492_000)

    private func pr(
        _ id: String, number: Int, repository: String = "me/app", title: String = "Shared work",
        host: String = "github.com", hoursAgo: Double = 1, merged: Bool = false
    ) -> PullRequest {
        PullRequest(
            id: id, title: title, url: URL(string: "https://\(host)/\(repository)/pull/\(number)")!,
            createdAt: now.addingTimeInterval(-hoursAgo * 3600), mergedAt: merged ? now : nil,
            repository: .init(nameWithOwner: repository)
        )
    }

    private func snapshot() -> MonthSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let opened = [
            pr("opaque-app", number: 42, hoursAgo: 2),
            pr("opaque-infra", number: 42, repository: "acme/infra"),
            pr("opaque-merged", number: 142, hoursAgo: 3, merged: true),
            pr("opaque-old", number: 7, hoursAgo: 48),
        ]
        return MonthSnapshot(
            login: "fixture", window: MonthWindow(containing: now, calendar: calendar), opened: opened,
            merged: [opened[2], pr("opaque-carried", number: 9, hoursAgo: 40 * 24, merged: true)],
            totalContributions: 0, fetchedAt: now
        )
    }

    @Test func hashNumberUsesExactURLNumberRatherThanTitleOrOpaqueID() {
        let prs = [
            pr("opaque-infra", number: 42, repository: "acme/infra"), pr("opaque-app", number: 42),
            pr("42", number: 142, title: "Reference #42"), pr("other", number: 420),
        ]
        let matches = PullRequestWorkspaceSearch("  #42\n").results(in: prs)
        print("Identity query #42 returned IDs: \(matches.map(\.id))")
        #expect(matches.map(\.id) == ["opaque-infra", "opaque-app"])
    }

    @Test func qualifiedNumberDisambiguatesRepositoriesWithoutCaseSensitivity() {
        let prs = [pr("app", number: 42), pr("infra", number: 42, repository: "acme/infra"), pr("long", number: 420)]
        #expect(PullRequestWorkspaceSearch(" ME/APP#42 ").results(in: prs).map(\.id) == ["app"])
        #expect(PullRequestWorkspaceSearch("acme/infra#42").results(in: prs).map(\.id) == ["infra"])
        #expect(PullRequestWorkspaceSearch("app#42").results(in: prs).isEmpty)
    }

    @Test func pastedURLsRespectTheHostAndIgnoreBrowserQueryAndFragment() {
        let prs = [pr("public", number: 42), pr("enterprise", number: 42, host: "git.example.test"), pr("other", number: 142)]
        for url in [
            "https://github.com/me/app/pull/42", "https://GITHUB.COM/ME/APP/pull/42/?diff=split#discussion_r123",
            "https://github.com/me/app/pull/42/files?diff=split#diff-abc", "https://github.com/me/app/pull/42/commits/abc",
        ] {
            #expect(PullRequestWorkspaceSearch(url).results(in: prs).map(\.id) == ["public"])
        }
        #expect(PullRequestWorkspaceSearch("https://git.example.test/me/app/pull/42#discussion").results(in: prs).map(\.id)
                == ["enterprise"])
        #expect(PullRequestWorkspaceSearch("https://other.example.test/me/app/pull/42").results(in: prs).isEmpty)
    }

    @Test func invalidAndMissingIdentitiesDoNotMatchByNumericSubstring() {
        let prs = [pr("opaque", number: 142)]
        for query in ["#42", "#0", "#-142", "#142x", "#", "me/app#42", "https://github.com/me/app/issues/142"] {
            #expect(PullRequestWorkspaceSearch(query).results(in: prs).isEmpty)
        }
        // Ordinary numeric text remains a title/repository search.
        #expect(PullRequestWorkspaceSearch("142").results(in: [pr("text", number: 9, title: "Fix 142 retries")]).map(\.id)
                == ["text"])
    }

    @Test func identitySearchKeepsTheMetricDayRepositoryAndFunnelBoundaries() {
        let snapshot = snapshot()
        let oldDay = snapshot.window.dayIndex(of: now.addingTimeInterval(-48 * 3600))!
        let cases: [(PRMetric, PullRequestScope, String?, FunnelPart?, String, [String])] = [
            (.opened, .today, nil, nil, "#42", ["opaque-infra", "opaque-app"]),
            (.opened, .month, "me/app", nil, "#42", ["opaque-app"]),
            (.opened, .today, nil, nil, "#7", []),
            (.opened, .day(oldDay), nil, nil, "#7", ["opaque-old"]),
            (.opened, .month, nil, .notMerged, "#142", []),
            (.merged, .today, nil, nil, "#142", ["opaque-merged"]),
            (.merged, .month, nil, .carriedIn, "#9", ["opaque-carried"]),
        ]
        for (metric, scope, repository, funnel, query, ids) in cases {
            let scoped = snapshot.listedPullRequests(for: metric, scope: scope, repository: repository, funnel: funnel, at: now)
            #expect(PullRequestWorkspaceSearch(query).results(in: scoped).map(\.id) == ids)
        }
    }

    @Test func hostedIdentityQueriesUpdateRowsAndCopyTargetsWithoutEscapingFilters() async throws {
        let pasteboard = NSPasteboard(name: .init("pr-workspace-r5-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let host = NSHostingView(rootView: PullRequestList(
            snapshot: snapshot(), metric: .opened, now: now, copyLinkPasteboard: pasteboard
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 288, height: 420), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        await settle(host)
        let field = try #require(descendants(of: host).compactMap { $0 as? NSTextField }.first { $0.placeholderString != nil })
        let picker = try #require(descendants(of: host).compactMap { $0 as? NSPopUpButton }.first)
        let scope = try #require(descendants(of: host).compactMap { $0 as? NSSegmentedControl }.first)

        await search("#42", field: field, host: host)
        let copy = try #require(descendants(of: host).compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel()?.hasPrefix("Copy links for") == true
        })
        #expect(copy.accessibilityLabel() == "Copy links for 2 PRs in this list")
        copy.sendAction(copy.action, to: copy.target)
        #expect(pasteboard.string(forType: .string) == "https://github.com/acme/infra/pull/42\nhttps://github.com/me/app/pull/42")

        picker.selectItem(withTitle: "me/app (2)")
        picker.sendAction(picker.action, to: picker.target)
        await settle(host)
        copy.sendAction(copy.action, to: copy.target)
        #expect(pasteboard.string(forType: .string) == "https://github.com/me/app/pull/42")

        await search("https://github.com/acme/infra/pull/42", field: field, host: host)
        #expect(!copy.isEnabled)
        await search("https://github.com/me/app/pull/7/files?diff=split#discussion", field: field, host: host)
        #expect(!copy.isEnabled)
        scope.selectedSegment = 1
        scope.sendAction(scope.action, to: scope.target)
        await settle(host)
        #expect(copy.isEnabled)
        copy.sendAction(copy.action, to: copy.target)
        #expect(pasteboard.string(forType: .string) == "https://github.com/me/app/pull/7")
        #expect(descendants(of: host).compactMap { $0 as? NSButton }.contains {
            $0.cell?.accessibilityLabel() == "Copy link: Shared work, me/app"
        })

        await search("", field: field, host: host)
        #expect(copy.accessibilityLabel() == "Copy links for 3 PRs in this list")
        #expect(picker.titleOfSelectedItem == "me/app (3)")
    }

    private func search(_ query: String, field: NSTextField, host: NSView) async {
        field.stringValue = query
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        await settle(host)
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<5 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
