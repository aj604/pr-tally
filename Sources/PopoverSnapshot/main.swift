import AppKit
import SwiftUI
import TallyCore
@_spi(Fixtures) import TallyUI

// Usage: swift run PopoverSnapshot <output.png> [light|dark|menubar|rollover|drilldown|overview|zoom-day|zoom-repo|zoom-metric|milestone]
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

/// Every ring state on light and dark menu bars, then the faded look of numbers that stopped updating, using no network.
@MainActor
func renderMenuBar(to path: String) throws {
    let window = MonthWindow(containing: Date())
    let middle = window.start.addingTimeInterval(window.end.timeIntervalSince(window.start) / 2)
    enum Look { case plain, green, faded }
    let early = Pace(goal: 1000, count: 83, window: window, at: window.start.addingTimeInterval(4 * 86_400))
    let states: [(String, Look, Pace?)] = [
        ("–", .plain, nil),
        ("12", .plain, early),
        ("41", .green, Pace(goal: 1000, count: 300, window: window, at: middle)),
        ("9", .plain, Pace(goal: 1000, count: 700, window: window, at: middle)),
        ("35", .green, Pace(goal: 1000, count: 1042, window: window, at: middle)),
        ("–", .faded, nil),
        ("12", .faded, early),
    ]
    // The glyphs draw in the label color, which a menu bar resolves from its own appearance.
    func drawn(_ image: NSImage, _ appearance: NSAppearance.Name) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { image.draw(in: rect) }
            return true
        }
    }
    func bar(_ background: Color, _ text: Color, _ appearance: NSAppearance.Name) -> some View {
        HStack(spacing: 16) {
            ForEach(states.indices, id: \.self) { index in
                let (title, look, pace) = states[index]
                HStack(spacing: 4) {
                    switch look {
                    case .green: Image(nsImage: drawn(MenuBarGlyph.image(for: pace, greenTitle: title), appearance))
                    case .faded: Image(nsImage: drawn(MenuBarGlyph.fadedImage(for: pace, title: title), appearance))
                    case .plain:
                        Image(nsImage: drawn(MenuBarGlyph.image(for: pace), appearance))
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
    try write(VStack(spacing: 0) { bar(Color(white: 0.93), .black, .aqua); bar(Color(white: 0.13), .white, .darkAqua) }, to: path)
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
/// `focusDay` (zero-based) or `focusRepository` opens the list zoomed to it, as from the charts or the top repos, and
/// `focusMetric` on the count the goal doesn't follow, as from that figure on the summary.
@MainActor
func renderFixture(
    to path: String, listOpen: Bool, focusDay: Int? = nil, focusRepository: String? = nil, focusMetric: PRMetric? = nil
) async throws {
    let now = Date()
    let window = MonthWindow(containing: now)
    let startOfToday = window.calendar.startOfDay(for: now)
    let titles = [
        ("me/app", "Fix crash when the token is missing"), ("me/app", "Bump the minimum macOS version to 14"),
        ("acme/infra", "Retry failed uploads with exponential backoff and a jitter that depends on the attempt"),
        ("acme/infra", "Add dashboards for queue depth"), ("me/dotfiles", "Tidy zsh startup"),
    ]
    // Infrastructure changes run several times the size of the app's, and dotfile tweaks are a few lines.
    func size(_ repo: String, _ index: Int) -> (additions: Int, deletions: Int) {
        let base = ["acme/infra": 180, "me/app": 40, "me/dotfiles": 6][repo] ?? 20
        return (base + index * 7 % 50, base / 3 + index * 3 % 20)
    }
    // Most older PRs merged a few hours to a day and a half after opening; the rest are open, draft or closed.
    let earlier = (0..<40).map { index -> PullRequest in
        let (repo, title) = titles[index % titles.count]
        let createdAt = max(window.start, startOfToday.addingTimeInterval(-TimeInterval(index + 1) * 20_000))
        let mergedAt = index % 4 == 3 ? nil : min(now, createdAt.addingTimeInterval(TimeInterval(index % 9 + 1) * 14_000))
        let state: PullRequest.State = mergedAt != nil ? .merged : index % 8 == 3 ? .open : .closed
        return PullRequest(
            id: "old\(index)", title: title, url: URL(string: "https://github.com/\(repo)/pull/\(index)")!,
            createdAt: createdAt, mergedAt: mergedAt, repository: .init(nameWithOwner: repo), state: state,
            isDraft: index == 3, additions: size(repo, index).additions, deletions: size(repo, index).deletions
        )
    }
    // Two of today's merged within the hour, so today has merges as well as openings.
    let today = titles.enumerated().map { index, entry in
        let createdAt = max(startOfToday, now.addingTimeInterval(-TimeInterval(index) * 3_100 - 60))
        let mergedAt = (1...2).contains(index) ? min(now, createdAt.addingTimeInterval(1_500)) : nil
        return PullRequest(
            id: "today\(index)", title: entry.1, url: URL(string: "https://github.com/\(entry.0)/pull/\(900 + index)")!,
            createdAt: createdAt, mergedAt: mergedAt,
            repository: .init(nameWithOwner: entry.0), state: mergedAt != nil ? .merged : .open, isDraft: index == 4,
            additions: size(entry.0, index).additions, deletions: size(entry.0, index).deletions
        )
    }
    let snapshot = MonthSnapshot(
        login: "me", window: window, opened: earlier + today, merged: (earlier + today).filter { $0.mergedAt != nil },
        totalContributions: 612, fetchedAt: now
    )
    let store = TallyStore(defaults: ScratchDefaults(), cache: nil) { snapshot }
    await store.refresh()
    if listOpen { store.screen = .pullRequests }
    let view = PopoverView(store: store, focusDay: focusDay, focusRepository: focusRepository, focusMetric: focusMetric)
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
} else if mode == "zoom-day" {
    // Yesterday, or the 1st early in the month, as if picked from the per-day chart.
    let today = MonthWindow(containing: Date()).dayIndex(of: Date()) ?? 0
    try await renderFixture(to: path, listOpen: true, focusDay: max(0, today - 1))
} else if mode == "zoom-repo" {
    try await renderFixture(to: path, listOpen: true, focusRepository: "acme/infra")
} else if mode == "zoom-metric" {
    // The merged count, as from its figure beside the opened count the goal follows.
    try await renderFixture(to: path, listOpen: true, focusMetric: .merged)
} else if mode == "light" || mode == "dark" {
    try await renderPopover(to: path, scheme: mode == "dark" ? .dark : .light)
} else {
    // Only `light` and `dark` use your real login, so a mistyped fixture mode must not fall through to them.
    FileHandle.standardError.write(Data("Unknown mode \(mode). Use light, dark, menubar, rollover, drilldown, overview, zoom-day, zoom-repo, zoom-metric or milestone.\n".utf8))
    exit(2)
}
