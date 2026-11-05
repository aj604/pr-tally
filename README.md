# PR Tally

A little macOS menu bar app that tracks your GitHub pull requests for the month against a goal, so you can see where you stand at a glance.

The menu bar shows a progress ring for the month next to today's count. The ring is orange when you're behind pace and green when you're on or ahead of it, with a tick where a steady pace would be today. The number turns green once today's count beats the daily quota (goal ÷ days in the month). Click it for:

- Progress against the goal, with a marker where a steady pace would be today
- How far ahead or behind pace you are, PRs needed per day, and your projected month-end total
- A marker when today's count beats the daily quota (goal ÷ days in the month), even if you're still behind pace
- A running total chart and daily bars (hover for any day's numbers)
- Your top repos, plus merged PRs and total GitHub contributions

## Install

Requires macOS 14+, Xcode or the Swift toolchain, and the [GitHub CLI](https://cli.github.com) logged in (`gh auth login`).

```sh
./scripts/install.sh
```

This builds the app, copies it to `~/Applications/PR Tally.app`, and launches it. There's no Dock icon. To start it automatically, turn on **Launch at login** in settings (the gear in the popover).

## How it counts

- **Opened or merged:** the goal counts PRs you opened this month by default. Switch to merged in settings; the other number is always shown too.
- **Month boundaries:** months follow your Mac's time zone, so numbers can differ slightly from a date-only GitHub search, which uses UTC.
- **What's included:** every PR you authored that your token can see, in any repo and any state, including drafts and closed-unmerged PRs. Private repos need the `repo` scope, and SSO-protected orgs need the token authorized.
- **Past 1,000:** GitHub search stops at 1,000 results per query, so the app splits the month into smaller ranges and stays exact past that.
- **Contributions:** GitHub's profile-graph total for the month, which covers more than PRs.

## Refreshing

Numbers refresh every 15 minutes (configurable), after your Mac wakes, and when you open the popover if they're over a minute old. If a refresh fails, the last good numbers stay on screen with the error next to them.

## Auth

The app reads your token from `gh auth token`. To use a different account, save a personal access token in settings; it's stored in your keychain.

## Development

```sh
swift test                                    # run tests
./scripts/bundle.sh                           # build dist/PR Tally.app
swift run PopoverSnapshot out.png [dark]      # render the popover with live data
```

`TallyCore` holds the GitHub client and pace logic, `TallyUI` the store and views, and `PRTally` the app entry point.
