import AppKit
import SwiftUI
import Testing
import TallyCore
@testable import TallyUI

@MainActor @Suite struct PullRequestWorkspaceRepositoriesTests {
    private let now = Date(timeIntervalSince1970: 1_794_492_000)

    private var month: MonthWindow {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return MonthWindow(containing: now, calendar: calendar)
    }

    private func pr(
        _ id: String, repository: String, title: String = "Shared work", opened: Date? = nil, merged: Bool = false
    ) -> PullRequest {
        PullRequest(
            id: id, title: title, url: URL(string: "https://github.com/\(repository)/pull/\(id)")!,
            createdAt: opened ?? now.addingTimeInterval(-3600), mergedAt: merged ? now : nil,
            repository: .init(nameWithOwner: repository)
        )
    }

    private func snapshot() -> MonthSnapshot {
        let opened = [
            pr("1", repository: "me/app"), pr("2", repository: "me/app", title: "Other work"),
            pr("3", repository: "acme/infra"), pr("4", repository: "acme/infra", merged: true),
            pr("5", repository: "me/legacy", opened: now.addingTimeInterval(-48 * 3600)),
        ]
        return MonthSnapshot(
            login: "fixture", window: month, opened: opened,
            merged: [opened[3], pr("6", repository: "me/older", opened: month.start.addingTimeInterval(-3600), merged: true)],
            totalContributions: 0, fetchedAt: now
        )
    }

    @Test func choicesIncludeEveryRepositoryWithCountsInNameOrder() {
        let names = ["zeta/tool", "me/one", "acme/app", "me/two", "me/three", "me/four", "me/five"]
        let prs = names.enumerated().map { pr("\($0.offset)", repository: $0.element) }
            + [pr("extra", repository: "acme/app")]
        let choices = PullRequestWorkspaceRepositories(prs)
        #expect(choices.options.map(\.name) == names.sorted())
        #expect(choices.options.map(\.count) == [2, 1, 1, 1, 1, 1, 1])
        #expect(choices.totalCount == 8)
    }

    @Test func aMissingSelectionStaysVisibleAtZeroWithoutChangingTheTotal() {
        let choices = PullRequestWorkspaceRepositories([pr("1", repository: "me/app")], selected: "acme/absent")
        #expect(choices.options == [.init(name: "acme/absent", count: 0), .init(name: "me/app", count: 1)])
        #expect(choices.totalCount == 1)
        let empty = PullRequestWorkspaceRepositories([], selected: "me/app")
        #expect(empty.options == [.init(name: "me/app", count: 0)])
        #expect(empty.totalCount == 0)
        #expect(PullRequestWorkspaceRepositories([]).options.isEmpty)
    }

    @Test func listOffersARepositoryPicker() {
        let empty = MonthSnapshot(
            login: "fixture", window: month, opened: [], merged: [], totalContributions: 0, fetchedAt: now
        )
        let host = NSHostingView(rootView: PullRequestList(snapshot: empty, metric: .opened, now: now))
        host.frame = NSRect(x: 0, y: 0, width: 288, height: 420)
        host.layoutSubtreeIfNeeded()
        let pickers = descendants(of: host).compactMap { $0 as? NSPopUpButton }
        print("Repository picker titles: \(pickers.map(\.itemTitles))")
        #expect(pickers.count == 1)
        #expect(pickers.first?.itemTitles == ["All repositories (0)"])
        #expect(pickers.first?.accessibilityLabel() == "Repository")
    }

    @Test func hostedChoicesFollowTheMetricDayAndFunnel() async throws {
        let cases: [(PullRequestFocus, [String])] = [
            (.init(), ["All repositories (4)", "acme/infra (2)", "me/app (2)"]),
            (.init(day: month.dayIndex(of: now.addingTimeInterval(-48 * 3600))),
             ["All repositories (1)", "me/legacy (1)"]),
            (.init(metric: .merged), ["All repositories (2)", "acme/infra (1)", "me/older (1)"]),
            (.init(funnel: .notMerged), ["All repositories (4)", "acme/infra (1)", "me/app (2)", "me/legacy (1)"]),
            (.init(funnel: .carriedIn), ["All repositories (1)", "me/older (1)"]),
        ]
        for (focus, titles) in cases {
            let (host, window) = await hosted(focus: focus)
            defer { window.orderOut(nil) }
            let picker = try #require(descendants(of: host).compactMap { $0 as? NSPopUpButton }.first)
            #expect(picker.itemTitles == titles)
        }
    }

    @Test func choosingSwitchingAndClearingRepositoriesKeepsTheSearch() async throws {
        let (host, window) = await hosted()
        defer { window.orderOut(nil) }
        let picker = try #require(descendants(of: host).compactMap { $0 as? NSPopUpButton }.first)
        let field = try #require(descendants(of: host).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "Search title or repository"
        })
        let originalHeight = host.fittingSize.height
        field.stringValue = "Shared"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        await settle(host)
        let searchedHeight = host.fittingSize.height
        #expect(searchedHeight < originalHeight)
        let titles = picker.itemTitles

        select("me/app (2)", in: picker)
        await settle(host)
        let appHeight = host.fittingSize.height
        #expect(picker.titleOfSelectedItem == "me/app (2)")
        #expect(picker.itemTitles == titles)
        #expect(field.stringValue == "Shared")
        #expect(appHeight < searchedHeight)

        select("acme/infra (2)", in: picker)
        await settle(host)
        #expect(picker.titleOfSelectedItem == "acme/infra (2)")
        // One matching app PR, but two matching infra PRs; the repository chip occupies the same space in both.
        #expect(host.fittingSize.height > appHeight)
        #expect(picker.itemTitles == titles)
        #expect(field.stringValue == "Shared")

        select("All repositories (4)", in: picker)
        await settle(host)
        #expect(host.fittingSize.height == searchedHeight)
        #expect(field.stringValue == "Shared")
        field.stringValue = ""
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        await settle(host)
        #expect(host.fittingSize.height == originalHeight)
    }

    @Test func changingScopeKeepsAnEmptyRepositorySelectedAndLetsItBeCleared() async throws {
        let (host, window) = await hosted(focus: .init(repository: "me/legacy"))
        defer { window.orderOut(nil) }
        let picker = try #require(descendants(of: host).compactMap { $0 as? NSPopUpButton }.first)
        let scope = try #require(descendants(of: host).compactMap { $0 as? NSSegmentedControl }.first)
        #expect(picker.titleOfSelectedItem == "me/legacy (1)")
        scope.selectedSegment = 0
        scope.sendAction(scope.action, to: scope.target)
        await settle(host)
        #expect(picker.titleOfSelectedItem == "me/legacy (0)")
        #expect(picker.itemTitles == ["All repositories (4)", "acme/infra (2)", "me/app (2)", "me/legacy (0)"])
        select("All repositories (4)", in: picker)
        await settle(host)
        #expect(picker.titleOfSelectedItem == "All repositories (4)")
        #expect(picker.itemTitles == ["All repositories (4)", "acme/infra (2)", "me/app (2)"])
    }

    @Test func longRepositoryNamesFitThePopoverAndRemainWholeInTheMenu() async throws {
        let name = "a-very-long-organization/a-repository-with-a-long-name"
        let snapshot = MonthSnapshot(
            login: "fixture", window: month, opened: [pr("1", repository: name)], merged: [],
            totalContributions: 0, fetchedAt: now
        )
        let host = NSHostingView(rootView: PullRequestList(snapshot: snapshot, metric: .opened, now: now))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 288, height: 420), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        await settle(host)
        let picker = try #require(descendants(of: host).compactMap { $0 as? NSPopUpButton }.first)
        #expect(picker.itemTitles == ["All repositories (1)", "\(name) (1)"])
        #expect(picker.frame.width > 0 && picker.frame.width <= 288)
        #expect(picker.cell?.lineBreakMode == .byTruncatingMiddle)
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
