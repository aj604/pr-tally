import AppKit
import SwiftUI
import Testing
import TallyCore
@testable import TallyUI

/// ⌘[ and ⌘] step the day segment like its arrows, including while the search field is being typed in.
@MainActor @Suite(.serialized) struct PullRequestWorkspaceDayShortcutTests {
    private let zone = TimeZone(identifier: "America/New_York")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// November 2026, on the 12th.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 15))! }

    private func snapshot() -> MonthSnapshot {
        MonthSnapshot(
            login: "me", window: MonthWindow(containing: now, calendar: calendar), opened: [], merged: [],
            totalContributions: 0, fetchedAt: now
        )
    }

    @Test func theTooltipsNameTheShortcut() {
        let window = MonthWindow(containing: now, calendar: calendar)
        let stepper = PullRequestWorkspaceDayStepper(day: 6, in: window, at: now)
        #expect(PullRequestWorkspaceDayStepper.Step.previous.help(to: stepper.previous) == "Show Nov 6 (⌘[)")
        #expect(PullRequestWorkspaceDayStepper.Step.next.help(to: stepper.next) == "Show Nov 8 (⌘])")
        #expect(PullRequestWorkspaceDayStepper.Step.next.help(to: nil) == "Next day (⌘])")
    }

    @Test func commandBracketsStepTheDayAndStopAtToday() async throws {
        let (host, window) = await hosted(focus: PullRequestFocus(day: 9))
        defer { window.orderOut(nil) }
        #expect(try daySegment(in: host) == "Nov 10")
        await press("[", in: window, host)
        #expect(try daySegment(in: host) == "Nov 9")
        // A second press steps again rather than repeating the first step.
        await press("[", in: window, host)
        #expect(try daySegment(in: host) == "Nov 8")
        for _ in 0..<5 { await press("]", in: window, host) }
        #expect(try daySegment(in: host) == "Today")
    }

    @Test func theShortcutsStepWhileTypingASearch() async throws {
        let (host, window) = await hosted(focus: PullRequestFocus(day: 9))
        defer { window.orderOut(nil) }
        let field = try #require(descendants(of: host).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString?.hasPrefix("Search ") == true
        })
        window.makeFirstResponder(field)
        await press("]", in: window, host)
        #expect(try daySegment(in: host) == "Nov 11")
        #expect(field.stringValue.isEmpty)
    }

    @Test func theShortcutsRestWhileTheWholeMonthShows() async throws {
        let (host, window) = await hosted(focus: PullRequestFocus(day: 9))
        defer { window.orderOut(nil) }
        let control = try segmentedControl(in: host)
        control.selectedSegment = 1
        control.sendAction(control.action, to: control.target)
        await settle(host)
        await press("[", in: window, host)
        #expect(try daySegment(in: host) == "Nov 10")
    }

    private func hosted(focus: PullRequestFocus) async -> (NSHostingView<PullRequestList>, NSWindow) {
        let host = NSHostingView(rootView: PullRequestList(snapshot: snapshot(), metric: .opened, now: now, focus: focus))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 288, height: 420), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await settle(host)
        return (host, window)
    }

    private func press(_ key: String, in window: NSWindow, _ host: NSView) async {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
            keyCode: key == "[" ? 33 : 30
        )!
        _ = window.performKeyEquivalent(with: event)
        await settle(host)
    }

    private func segmentedControl(in host: NSView) throws -> NSSegmentedControl {
        try #require(descendants(of: host).compactMap { $0 as? NSSegmentedControl }.first)
    }

    private func daySegment(in host: NSView) throws -> String? {
        try segmentedControl(in: host).label(forSegment: 0)
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<5 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
