import AppKit
import SwiftUI
import TallyCore
import TallyUI

// Usage: swift run PopoverSnapshot <output.png> [light|dark|menubar|rollover]
@MainActor
func write(_ view: some View, to path: String) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 4
    guard let image = renderer.cgImage,
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: URL(fileURLWithPath: path))
    print("-> \(path)")
}

@MainActor
func renderPopover(to path: String, scheme: ColorScheme) async throws {
    let client = GitHubClient(tokens: TokenProvider())
    let store = TallyStore { try await client.fetchSnapshot() }
    await store.refresh()
    let view = PopoverView(store: store)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
    try write(view, to: path)
}

/// Every ring state on light and dark menu bars, using no network.
@MainActor
func renderMenuBar(to path: String) throws {
    let window = MonthWindow(containing: Date())
    let middle = window.start.addingTimeInterval(window.end.timeIntervalSince(window.start) / 2)
    let states: [(String, Bool, Pace?)] = [
        ("–", false, nil),
        ("12", false, Pace(goal: 1000, count: 83, window: window, at: window.start.addingTimeInterval(4 * 86_400))),
        ("41", true, Pace(goal: 1000, count: 300, window: window, at: middle)),
        ("9", false, Pace(goal: 1000, count: 700, window: window, at: middle)),
        ("35", true, Pace(goal: 1000, count: 1042, window: window, at: middle)),
    ]
    func bar(_ background: Color, _ text: Color) -> some View {
        HStack(spacing: 16) {
            ForEach(states.indices, id: \.self) { index in
                let (title, beatingPace, pace) = states[index]
                HStack(spacing: 4) {
                    if beatingPace {
                        Image(nsImage: MenuBarGlyph.image(for: pace, greenTitle: title))
                    } else {
                        Image(nsImage: MenuBarGlyph.image(for: pace))
                        Text(title).monospacedDigit().foregroundStyle(text)
                    }
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(background)
    }
    try write(VStack(spacing: 0) { bar(Color(white: 0.93), .black); bar(Color(white: 0.13), .white) }, to: path)
}

private struct Offline: LocalizedError {
    var errorDescription: String? { "The Internet connection appears to be offline." }
}

/// A relaunch in a new month with only last month's numbers saved and GitHub out of reach, using no network.
@MainActor
func renderRollover(to path: String) async throws {
    let lastMonth = MonthWindow(containing: Date()).start.addingTimeInterval(-86_400)
    let prs = (0..<842).map {
        PullRequest(
            id: "\($0)", title: "", url: URL(string: "https://github.com")!,
            createdAt: lastMonth.addingTimeInterval(TimeInterval(-3_000 * $0)), mergedAt: nil,
            repository: .init(nameWithOwner: "me/app")
        )
    }
    let snapshot = MonthSnapshot(
        login: "me", window: MonthWindow(containing: lastMonth), opened: prs, merged: [], totalContributions: 0,
        fetchedAt: lastMonth
    )
    let cache = SnapshotCache(url: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    cache.save(snapshot)
    let store = TallyStore(cache: cache) { throw Offline() }
    await store.refresh()
    let view = PopoverView(store: store).background(Color(nsColor: .windowBackgroundColor))
    try write(view, to: path)
    print("menu bar: \(store.menuBarTitle()) | \(store.menuBarAccessibilityLabel)")
}

let arguments = CommandLine.arguments
let path = arguments.count > 1 ? arguments[1] : "popover.png"
let mode = arguments.count > 2 ? arguments[2] : "light"
if mode == "menubar" {
    try renderMenuBar(to: path)
} else if mode == "rollover" {
    try await renderRollover(to: path)
} else {
    try await renderPopover(to: path, scheme: mode == "dark" ? .dark : .light)
}
