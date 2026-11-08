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

@MainActor @Suite(.serialized) struct MonthInsightBestDaySummaryTests {
    @Test func theLabelIncludesTheCountAndLocalDate() throws {
        let fixture = snapshot([1, 1, 3])
        let best = try #require(MonthInsightBestDay(snapshot: fixture, metric: .opened, at: date(4)))
        let text = MonthInsightBestDayText(best: best, metric: .opened, window: fixture.window)
        #expect(text.summary == "Best day: 2 · \(fixture.window.dayTitle(0))")
        #expect(text.help == "List 2 PRs opened on \(fixture.window.dayTitle(0)).")
    }

    @Test func tiedDaysExplainTheMostRecentChoiceAndSelectedMetric() throws {
        let fixture = snapshot([1, 3], metric: .merged)
        let best = try #require(MonthInsightBestDay(snapshot: fixture, metric: .merged, at: date(4)))
        let text = MonthInsightBestDayText(best: best, metric: .merged, window: fixture.window)
        #expect(text.summary == "Best day: 1 · \(fixture.window.dayTitle(2))")
        #expect(text.help == "List 1 PR merged on \(fixture.window.dayTitle(2)). Most recent of 2 days tied for best this month.")
    }

    @Test func theDatedShortcutFitsBesideThePerDayHeading() throws {
        let fixture = snapshot(Array(repeating: 30, count: 1000))
        let view = HStack {
            Text("Per day").font(.caption.weight(.medium))
            Spacer()
            MonthInsightBestDaySummary(snapshot: fixture, metric: .opened, now: date(30))
        }
        let renderer = ImageRenderer(content: view.frame(width: 288))
        let image = try #require(renderer.cgImage)
        #expect(image.width == 288)
        #expect(image.height > 0)
        #expect(image.height <= 20)
    }

    @Test func pressingTheShortcutSelectsTheBestDayAndListsItsPRs() async throws {
        for metric in PRMetric.allCases {
            let fixture = snapshot([1, 1, 3, 3, 4], metric: metric)
            var selectedDay: Int?
            let shortcut = MonthInsightBestDaySummary(snapshot: fixture, metric: metric, now: date(5)) { selectedDay = $0 }
            let host = NSHostingView(rootView: shortcut.frame(width: 220, height: 30))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 220, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            for _ in 0..<5 { await Task.yield() }
            let center = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: center, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ))
                window.sendEvent(event)
            }
            #expect(selectedDay == 2)
            let day = try #require(selectedDay)
            let scope = PullRequestScope.opening(for: PullRequestFocus(day: day), in: fixture, metric: metric, at: date(5))
            #expect(scope == .day(2))
            #expect(fixture.listedPullRequests(for: metric, scope: scope, at: date(5)).map(\.id).sorted() == ["2", "3"])
        }
    }

    @Test func aQuietMonthDoesNotSelectADay() async throws {
        var selectedDay: Int?
        let view = MonthInsightBestDaySummary(snapshot: snapshot([]), metric: .opened, now: date(5)) { selectedDay = $0 }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<5 { await Task.yield() }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: host.bounds.midX, y: host.bounds.midY), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
        }
        #expect(selectedDay == nil)
    }
}
