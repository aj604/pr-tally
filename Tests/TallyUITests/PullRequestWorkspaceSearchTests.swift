import AppKit
import SwiftUI
import Testing
import TallyCore
@testable import TallyUI

@MainActor @Suite struct PullRequestWorkspaceSearchTests {
    private let now = Date(timeIntervalSince1970: 1_794_492_000)

    private func snapshot() -> MonthSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let window = MonthWindow(containing: now, calendar: calendar)
        return MonthSnapshot(
            login: "fixture", window: window,
            opened: [
                pr("1", "Fix café upload", hoursAgo: 2), pr("2", "Retry uploads", repository: "acme/infra"),
                pr("3", "Fix café upload", hoursAgo: 48), pr("4", "Fix café upload", hoursAgo: 0.5, merged: true),
            ],
            merged: [pr("4", "Fix café upload", hoursAgo: 0.5, merged: true)], totalContributions: 0, fetchedAt: now
        )
    }

    private func pr(
        _ id: String, _ title: String, repository: String = "me/app", hoursAgo: Double = 1, merged: Bool = false
    ) -> PullRequest {
        PullRequest(
            id: id, title: title, url: URL(string: "https://github.com/\(repository)/pull/\(id)")!,
            createdAt: now.addingTimeInterval(-hoursAgo * 3600), mergedAt: merged ? now : nil,
            repository: .init(nameWithOwner: repository)
        )
    }

    @Test func titleSearchIgnoresCaseAccentsAndSurroundingWhitespace() {
        let prs = [pr("1", "Fix café upload"), pr("2", "Retry uploads")]
        #expect(PullRequestWorkspaceSearch("  CAFE \n").results(in: prs).map(\.id) == ["1"])
    }

    @Test func repositorySearchMatchesOwnerOrName() {
        let prs = [pr("1", "Fix café upload"), pr("2", "Retry uploads", repository: "Acme/Infra")]
        #expect(PullRequestWorkspaceSearch("ACME").results(in: prs).map(\.id) == ["2"])
        #expect(PullRequestWorkspaceSearch("infra").results(in: prs).map(\.id) == ["2"])
    }

    @Test func blankSearchRestoresTheSameListAndOrder() {
        let prs = [pr("2", "Retry uploads"), pr("1", "Fix café upload")]
        for text in ["", " \n\t"] {
            let search = PullRequestWorkspaceSearch(text)
            #expect(!search.isActive)
            #expect(search.results(in: prs) == prs)
        }
    }

    @Test func noMatchIsEmptyRatherThanFallingBackToAllPRs() {
        #expect(PullRequestWorkspaceSearch("unknown").results(in: snapshot().opened).isEmpty)
    }

    @Test func searchKeepsTheMetricDayRepositoryAndFunnelBoundaries() {
        let snapshot = snapshot()
        let search = PullRequestWorkspaceSearch("upload")
        let today = snapshot.listedPullRequests(for: .opened, scope: .today, funnel: .notMerged, at: now)
        #expect(search.results(in: today).map(\.id) == ["2", "1"])
        let repo = snapshot.listedPullRequests(
            for: .opened, scope: .month, repository: "me/app", funnel: .notMerged, at: now
        )
        #expect(search.results(in: repo).map(\.id) == ["1", "3"])
        let merged = snapshot.listedPullRequests(for: .merged, scope: .today, at: now)
        #expect(search.results(in: merged).map(\.id) == ["4"])
        let day = snapshot.window.dayIndex(of: now.addingTimeInterval(-48 * 3600))!
        let picked = snapshot.listedPullRequests(for: .opened, scope: .day(day), at: now)
        #expect(search.results(in: picked).map(\.id) == ["3"])
    }

    @Test func filteringPreservesCountedDateOrderAndLinkDestinations() {
        let snapshot = snapshot()
        let scoped = snapshot.listedPullRequests(for: .opened, scope: .month, at: now)
        let matches = PullRequestWorkspaceSearch("cafe").results(in: scoped)
        #expect(matches.map(\.id) == ["4", "1", "3"])
        #expect(matches.map(\.url) == ["4", "1", "3"].map { URL(string: "https://github.com/me/app/pull/\($0)")! })
    }

    @Test func listOffersSearchWithoutLeavingTheCount() {
        let host = NSHostingView(rootView: PullRequestList(snapshot: snapshot(), metric: .opened, now: now))
        host.frame = NSRect(x: 0, y: 0, width: 288, height: 420)
        host.layoutSubtreeIfNeeded()
        let fields = descendants(of: host).compactMap { $0 as? NSTextField }
        #expect(fields.contains { $0.placeholderString == "Search title, repo, # or URL" })
    }

    @Test func typingIntoTheHostedFieldUpdatesTheList() async throws {
        let host = NSHostingView(rootView: PullRequestList(snapshot: snapshot(), metric: .opened, now: now))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 288, height: 420), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<5 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
        let originalHeight = host.fittingSize.height
        let field = try #require(descendants(of: host).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "Search title, repo, # or URL"
        })
        field.stringValue = "infra"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        for _ in 0..<5 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height < originalHeight)
        field.stringValue = ""
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        for _ in 0..<5 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height == originalHeight)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
