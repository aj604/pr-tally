import AppKit
import SwiftUI
import TallyCore
import TallyUI

// Usage: swift run PopoverSnapshot <output.png> [light|dark|menubar|rollover|drilldown|overview|milestone]
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

/// For views with AppKit-backed controls (pickers, scroll views), which `ImageRenderer` draws as placeholders.
@MainActor
func writeHosted(_ view: some View, to path: String) throws {
    let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: view)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds),
        let png = { host.cacheDisplay(in: host.bounds, to: rep); return rep.representation(using: .png, properties: [:]) }()
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
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let cache = SnapshotCache(url: url)
    cache.save(snapshot)
    let store = TallyStore(defaults: ScratchDefaults(), cache: cache) { throw Offline() }
    await store.refresh()
    let view = PopoverView(store: store).background(Color(nsColor: .windowBackgroundColor))
    try write(view, to: path)
    print("menu bar: \(store.menuBarTitle()) | \(store.menuBarAccessibilityLabel)")
}

/// A busy day in a few repositories, with the pull request list open (or, for `overview`, closed), using no network.
@MainActor
func renderFixture(to path: String, listOpen: Bool) async throws {
    let now = Date()
    let window = MonthWindow(containing: now)
    let startOfToday = window.calendar.startOfDay(for: now)
    let titles = [
        ("me/app", "Fix crash when the token is missing"), ("me/app", "Bump the minimum macOS version to 14"),
        ("acme/infra", "Retry failed uploads with exponential backoff and a jitter that depends on the attempt"),
        ("acme/infra", "Add dashboards for queue depth"), ("me/dotfiles", "Tidy zsh startup"),
    ]
    let earlier = (0..<40).map { index -> PullRequest in
        let (repo, title) = titles[index % titles.count]
        return PullRequest(
            id: "old\(index)", title: title, url: URL(string: "https://github.com/\(repo)/pull/\(index)")!,
            createdAt: max(window.start, startOfToday.addingTimeInterval(-TimeInterval(index + 1) * 20_000)),
            mergedAt: nil, repository: .init(nameWithOwner: repo)
        )
    }
    let today = titles.enumerated().map { index, entry in
        PullRequest(
            id: "today\(index)", title: entry.1, url: URL(string: "https://github.com/\(entry.0)/pull/\(900 + index)")!,
            createdAt: max(startOfToday, now.addingTimeInterval(-TimeInterval(index) * 3_100 - 60)), mergedAt: nil,
            repository: .init(nameWithOwner: entry.0)
        )
    }
    let snapshot = MonthSnapshot(
        login: "me", window: window, opened: earlier + today, merged: [], totalContributions: 612, fetchedAt: now
    )
    let store = TallyStore(defaults: ScratchDefaults(), cache: nil) { snapshot }
    await store.refresh()
    if listOpen { store.screen = .pullRequests }
    let view = PopoverView(store: store)
        .background(Color(nsColor: .windowBackgroundColor))
    try writeHosted(view, to: path)
}

/// Settings held in memory, so a run never touches the user's real ones.
private final class ScratchDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: nil)! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func string(forKey key: String) -> String? { values[key] as? String }
}

/// Counts creeping up to a goal of 100 over several refreshes, and what the store would send, using no network.
@MainActor
func runMilestone() async {
    let now = Date()
    @Sendable func snapshot(_ count: Int) -> MonthSnapshot {
        let prs = (0..<count).map {
            PullRequest(
                id: "\($0)", title: "", url: URL(string: "https://github.com")!, createdAt: now, mergedAt: nil,
                repository: .init(nameWithOwner: "me/app")
            )
        }
        return MonthSnapshot(
            login: "me", window: MonthWindow(containing: now), opened: prs, merged: [], totalContributions: 0,
            fetchedAt: now
        )
    }
    let counts = Counter([97, 99, 100, 104, 100])
    let defaults = ScratchDefaults()
    let store = TallyStore(defaults: defaults, notify: { print("  NOTIFY: \($0.title) | \($0.body)") }) {
        snapshot(await counts.next())
    }
    store.goal = 100
    for _ in 0..<5 {
        await store.refresh()
        print("count \(store.count ?? -1)")
    }
}

private actor Counter {
    private var values: [Int]
    init(_ values: [Int]) { self.values = values }
    func next() -> Int { values.removeFirst() }
}

let arguments = CommandLine.arguments
let path = arguments.count > 1 ? arguments[1] : "popover.png"
let mode = arguments.count > 2 ? arguments[2] : "light"
if mode == "milestone" {
    await runMilestone()
} else if mode == "menubar" {
    try renderMenuBar(to: path)
} else if mode == "rollover" {
    try await renderRollover(to: path)
} else if mode == "drilldown" || mode == "overview" {
    try await renderFixture(to: path, listOpen: mode == "drilldown")
} else if mode == "light" || mode == "dark" {
    try await renderPopover(to: path, scheme: mode == "dark" ? .dark : .light)
} else {
    // Only `light` and `dark` use your real login, so a mistyped fixture mode must not fall through to them.
    FileHandle.standardError.write(Data("Unknown mode \(mode). Use light, dark, menubar, rollover, drilldown, overview or milestone.\n".utf8))
    exit(2)
}
