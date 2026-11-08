# Contributing

## Setup

```sh
./scripts/doctor.sh                     # checks macOS, Xcode, gh; says how to fix what's missing
swift test --skip KeychainTokenTests    # should pass on a fresh clone
./scripts/install.sh                    # build, install to ~/Applications, launch
```

On macOS 27 the Command Line Tools can't compile SwiftUI (`plugin for module 'SwiftUIMacros' not found`). `bundle.sh` and `install.sh` switch to Xcode on their own; `swift test` and `swift run` don't. Select Xcode once with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, or prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

There's no Xcode project. Open the folder in Xcode (`xed .`) or use any editor with SourceKit-LSP.

## Layout

Three targets, with dependencies pointing one way: `PRTally` → `TallyUI` → `TallyCore`.

| Target | What lives there | Key files |
| --- | --- | --- |
| `TallyCore` | GitHub access and the month's math. No SwiftUI. | `GitHubClient` (GraphQL search, splitting past 1,000 results, retries), `GitHubRateLimit`, `TokenProvider` (saved token, then `gh`), `KeychainToken`, `MonthWindow`, `MonthSnapshot`, `Pace`, `MonthProjection`, `MonthFunnel`, `MonthInsight*` |
| `TallyUI` | State and views. | `TallyStore` (refresh schedule, settings, pause, staleness) plus its `TallyStore*` helpers (cache, network, milestones, notifications), `PopoverView`, `PopoverViewPullRequests`, `MonthCharts`, `MenuBarGlyph`, `SettingsView` |
| `PRTally` | App entry point. Wires the real client, keychain, cache and notifier into `TallyStore`. | `PRTallyApp.swift` |
| `PopoverSnapshot` | Dev tool that renders views to PNG. | `main.swift` |

A refresh runs: `TallyStore.refresh()` → the injected `Fetch` closure → `GitHubClient.fetchSnapshot()` → `MonthSnapshot`. Views read derived values (`Pace`, insights, funnel) from the store; none of them fetch.

File names group by feature: `MonthInsight*` in `TallyCore` computes a figure and the matching `MonthInsight*Summary`/`Status` in `TallyUI` shows it. `PullRequestWorkspace*` is the PR list, `Workflow*` the settings sections, `TallyStore*` the store's collaborators. Follow the pattern for new features.

## Testing

Tests use Swift Testing (`import Testing`, `@Test`, `#expect`). Nothing touches the network or your real settings:

- `GitHubClient(transport:)` takes a fake GraphQL transport. `FakeGitHub` in `GitHubClientTests.swift` mimics search, including the 1,000-result cap.
- `TallyStore` takes `defaults:`, `cache:`, `notify:` and a `Fetch` closure, so tests pass in-memory settings and canned snapshots.
- Many suites pin dates to November 2026. Use a fixed calendar or date rather than `Date()` when the result depends on the day.

`KeychainTokenTests` (in `GitHubClientTests.swift`) writes and deletes a throwaway login-keychain item; skip it unless you're changing `KeychainToken`.

Put pure logic in `TallyCore` with a test in `TallyCoreTests`. Put view-facing text and choices in a small struct (see `MonthInsightBestDayText`) so `TallyUITests` can check it without rendering.

## Seeing your change

```sh
swift run PopoverSnapshot out.png overview     # popover from fixture data, no network
swift run PopoverSnapshot out.png drilldown    # PR list open
swift run PopoverSnapshot out.png menubar      # every ring state, light and dark
swift run PopoverSnapshot out.png rollover     # new month, old numbers only
swift run PopoverSnapshot out.png milestone    # prints goal notifications instead of an image
swift run PopoverSnapshot out.png [light|dark] # live data with your real login
```

Notifications and launch at login only work from the bundled app, so check those with `./scripts/install.sh`.

## Changing behavior

- `README.md` is the user manual. When you change what the app shows or does, update it in the same PR, in plain terms a user would recognize.
- Comments say why, not what. Doc comments on types state the rule the type enforces (see `MonthFunnel.swift`).
- Keep it small: no dependencies, no abstractions without a second caller.
