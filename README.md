# PR Tally

A little macOS menu bar app that tracks your GitHub pull requests for the month against a goal, so you can see where you stand at a glance.

The menu bar shows a progress ring for the month next to today's count. The ring is orange when you're behind pace and green when you're on or ahead of it, with a tick where a steady pace would be today. The number turns green once today's count beats the daily quota (goal ÷ days in the month). Click it for:

- Progress against the goal, with a marker where a steady pace would be today
- How far ahead or behind pace you are, PRs needed per day, and your projected month-end total
- A marker when today's count beats the daily quota (goal ÷ days in the month), even if you're still behind pace
- A running total chart and daily bars (hover for any day's numbers)
- Your top repos, plus merged PRs and total GitHub contributions
- The PRs behind the count: **See the N PRs** lists today's or the whole month's, and clicking one opens it on GitHub

The popover always reopens on the numbers, even if you closed it on the list or in settings.

You also get one notification a month when a refresh takes you past your goal. macOS asks for permission the first time, and you can turn it off in settings. A goal already met the first time the app sees that month's numbers doesn't notify. Once it has notified, it stays quiet for the rest of the month, even if you raise the goal or switch to the other metric.

## Install

Requires macOS 14+, Xcode or the Swift toolchain, and the [GitHub CLI](https://cli.github.com) logged in (`gh auth login`).

```sh
./scripts/install.sh
```

This builds the app, copies it to `~/Applications/PR Tally.app`, and launches it. There's no Dock icon. To start it automatically, turn on **Launch at login** in settings (the gear in the popover).

## How it counts

- **Opened or merged:** the goal counts PRs you opened this month by default. Switch to merged in settings; the other number is always shown too.
- **Month boundaries:** months follow your Mac's time zone, so numbers can differ slightly from a date-only GitHub search, which uses UTC.
- **What's included:** every PR you authored that your token can see, in any repo and any state, including drafts and closed-unmerged PRs. Private repos need the `repo` scope, and SSO-protected orgs need the token authorized. A token that can't see your private repos undercounts with no error.
- **Past 1,000:** GitHub search stops at 1,000 results per query, so the app splits the month into smaller ranges and stays exact past that.
- **Contributions:** GitHub's profile-graph total for the month, which covers more than PRs.

## Refreshing

Numbers refresh every 15 minutes (configurable), after your Mac wakes, when the day or time zone changes, and when you open the popover if they're over a minute old. Closing the popover doesn't stop a refresh that's under way.

- **Failures:** the last good numbers stay on screen with the error next to them. A brief GitHub or network failure is retried on the spot, and a failed scheduled refresh tries again a minute later.
- **Rate limits:** if GitHub limits your token, the app sends nothing with that token until the limit lifts, for an hour at most, and says when that will be.
- **Relaunching:** the last good numbers are saved in `~/Library/Application Support/PR Tally/last-snapshot.json`, readable only by you, and show right away until the first refresh finishes. The file includes PR titles and repo names, and it stays when you change or clear a token.
- **A new month:** last month's numbers aren't shown as this month's. The ring empties and the popover says it's waiting for the new month's numbers, with where the old month ended.

## Auth

The app reads your token from `gh auth token`, looking for `gh` in `/opt/homebrew/bin`, `/usr/local/bin` and `/usr/bin`. If yours is installed somewhere else, save a token in settings instead.

It checks with `gh` about once a minute, so `gh auth switch` takes effect on the next refresh after that. A failed read keeps the current token, because it may only be a brief problem, so a logout can take three refreshes to show.

To use a different account, save a token in settings; it's stored in your keychain. Use a classic token with the `repo` scope, authorized for any SSO orgs. A fine-grained token covers one account or org, so if your PRs are in private repos under more than one, counts can come up short with no error. Settings warns you when it sees one.

## Development

```sh
swift test                                    # run tests
./scripts/bundle.sh                           # build dist/PR Tally.app
swift run PopoverSnapshot out.png [dark]      # render the popover with live data, using your real login
swift run PopoverSnapshot out.png <mode>      # render or run a fixture, with no network or login
```

The fixture modes are `rollover` (waiting for a new month), `overview`, `drilldown` (the PR list), `menubar` (the ring's states) and `milestone`, which prints what the goal notification would say rather than writing an image.

`KeychainTokenTests` adds and removes a throwaway item in your login keychain. Add `--skip KeychainTokenTests` to `swift test` to leave it out. Notifications only work from the bundled app, so they do nothing under `swift run`.

`TallyCore` holds the GitHub client and pace logic, `TallyUI` the store and views, and `PRTally` the app entry point.
