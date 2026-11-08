import AppKit
import SwiftUI
import Testing
import TallyCore
@testable import TallyUI

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!
    return calendar
}()

private func date(_ day: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day))!
}

private func snapshot(_ days: [Int], metric: PRMetric = .opened) -> MonthSnapshot {
    let prs = days.enumerated().map { index, day in
        PullRequest(
            id: "\(index)", title: "Fixture", url: URL(string: "https://example.test/\(index)")!,
            createdAt: metric == .merged ? date(0) : date(day), mergedAt: metric == .merged ? date(day) : nil,
            repository: .init(nameWithOwner: "me/app")
        )
    }
    return MonthSnapshot(
        login: "me", window: MonthWindow(containing: date(1), calendar: calendar),
        opened: metric == .opened ? prs : [], merged: metric == .merged ? prs : [], totalContributions: 0, fetchedAt: date(30)
    )
}

@MainActor @Suite(.serialized) struct MonthInsightGoalDayStatusTests {
    @Test func labelNamesTheLocalDateAndHelpClarifiesTheCurrentGoalAndMetric() throws {
        for metric in PRMetric.allCases {
            let fixture = snapshot([1, 3, 3, 8], metric: metric)
            let reached = try #require(MonthInsightGoalDay(snapshot: fixture, metric: metric, goal: 3, at: date(10)))
            let text = MonthInsightGoalDayText(reached: reached, goal: 3, metric: metric, window: fixture.window)
            #expect(text.summary == "Goal hit \(fixture.window.dayTitle(2)) 🎉")
            #expect(text.help == "Current goal of 3 PRs \(metric.rawValue) first reached on \(fixture.window.dayTitle(2)). List that day's PRs.")
        }
    }

    @Test func datedStatusFitsTheExistingProgressRowWithoutAddingHeight() throws {
        let fixture = snapshot([30])
        let pace = Pace(goal: 1, count: 1, window: fixture.window, at: date(30))
        let view = HStack(alignment: .firstTextBaseline) {
            MonthInsightGoalDayStatus(snapshot: fixture, metric: .opened, pace: pace, now: date(30))
            Spacer(minLength: 8)
        }
        let renderer = ImageRenderer(content: view.frame(width: 288))
        let image = try #require(renderer.cgImage)
        #expect(image.width == 288)
        #expect(image.height > 0)
        #expect(image.height <= 22)
    }

    @Test func pressingTheStatusListsTheCrossingDaysPRsForEitherMetric() async throws {
        for metric in PRMetric.allCases {
            let fixture = snapshot([1, 3, 3, 8], metric: metric)
            let pace = Pace(goal: 3, count: 4, window: fixture.window, at: date(10))
            var selectedDay: Int?
            let status = MonthInsightGoalDayStatus(snapshot: fixture, metric: metric, pace: pace, now: date(10)) { selectedDay = $0 }
            try await click(status)
            #expect(selectedDay == 2)
            let day = try #require(selectedDay)
            let scope = PullRequestScope.opening(for: PullRequestFocus(day: day), in: fixture, metric: metric, at: date(10))
            #expect(scope == .day(2))
            #expect(fixture.listedPullRequests(for: metric, scope: scope, at: date(10)).map(\.id).sorted() == ["1", "2"])
        }
    }

    @Test func unreachedGoalKeepsThePaceStatusWithoutADayAction() async throws {
        let fixture = snapshot([1, 3])
        let pace = Pace(goal: 10, count: 2, window: fixture.window, at: date(10))
        var selectedDay: Int?
        let status = MonthInsightGoalDayStatus(snapshot: fixture, metric: .opened, pace: pace, now: date(10)) { selectedDay = $0 }
        try await click(status)
        #expect(selectedDay == nil)
        let expected = ImageRenderer(content: Text(pace.statusText).font(.callout.weight(.medium)).foregroundStyle(pace.statusColor))
        let actual = ImageRenderer(content: status)
        #expect(try #require(actual.cgImage).width == #require(expected.cgImage).width)
        #expect(try #require(actual.cgImage).height == #require(expected.cgImage).height)
    }

    private func click(_ view: some View) async throws {
        let host = NSHostingView(rootView: view.frame(width: 240, height: 30))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<5 { await Task.yield() }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: host.bounds.midX, y: host.bounds.midY), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }
}
