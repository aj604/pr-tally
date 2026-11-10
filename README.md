# PR Tally

A little macOS menu bar app that tracks your GitHub pull requests for the month against a goal, so you can see where you stand at a glance.

The menu bar shows a progress ring for the month next to today's count. The ring is orange when you're behind pace and green when you're on or ahead of it, with a tick where a steady pace would be today. Today's number turns green once it beats the daily quota (goal ÷ days in the month). In Settings, choose **Month progress** to show the monthly count/goal instead; that number turns green when the goal is reached. Click the menu bar item for:

- Progress against the goal, with a marker where a steady pace would be today
- How far ahead or behind pace you are, PRs needed per day from the start of today (so it holds steady as you work), how many more today needs ("4 more today"), and your projected month-end total
- A marker when today's count beats the daily quota (goal ÷ days in the month), even if you're still behind pace. "N more today" stays beside it while today is still short of its share of the goal
- A running total chart and daily bars (hover for any day's numbers, click one to list that day's PRs)
- A dated best-day shortcut, plus current and best activity streaks within the month
- Recent activity over up to seven completed days in this month, compared with the preceding seven once fourteen full days exist; today is excluded
- A dated goal-hit shortcut that lists the PRs from the day the current goal was first reached
- Your top repos (click one to list its PRs this month), plus merged PRs and total GitHub contributions. In the merge funnel, click "Opened this month" to list the PRs opened this month that haven't merged, or "N older PRs also merged" to list those merged this month that were opened before it. Click the Opened or Merged figure your goal doesn't count to list those PRs
- The PRs behind the count: **See the N PRs** lists today's or the whole month's, and clicking one opens it on GitHub. A day or repo picked from the summary shows as a filter; click its × to go back to the whole list

In the PR list, choose a repository or search titles and repository names. Use `#123`, `owner/repository#123`, or a pasted PR URL for exact lookup. Search stays within the selected day, repository, metric, and merge-funnel filters. **Copy link** copies one PR's URL; **Copy links** copies every matching URL, one per line in list order, including rows beyond the scroll viewport.

Opened and merged PRs each keep their own monthly goal. Switch metrics in Settings to edit the matching target; the planning preview shows its daily average, remaining PRs, and how many more are needed today. Existing installations start both targets at the previously saved goal.

The popover always reopens on the numbers, even if you closed it on the list or in settings.

You also get a notification when a refresh takes you past your goal. macOS asks for permission the first time, and you can turn it off in Settings. A goal already met the first time the app sees that month's numbers doesn't notify. Each target (month, metric, and goal value) is announced at most once, so a raised goal or the other metric can notify when a later refresh crosses it.

## Install

Requires macOS 14+, Xcode (or, before macOS 27, the Command Line Tools), and the [GitHub CLI](https://cli.github.com) logged in (`gh auth login`).

```sh
./scripts/doctor.sh    # optional: checks the above and says how to fix what's missing
./scripts/install.sh
```

This builds the app, copies it to `~/Applications/PR Tally.app`, and launches it. If the Command Line Tools are your active developer directory, it builds with Xcode instead, since on macOS 27 the Command Line Tools can't compile SwiftUI. There's no Dock icon. To start it automatically, turn on **Launch at login** in settings (the gear in the popover).

## How it counts

- **Opened or merged:** the goal counts PRs you opened this month by default. Switch to merged in settings; the other number is always shown too.
- **Month boundaries:** months follow your Mac's time zone, so numbers can differ slightly from a date-only GitHub search, which uses UTC.
- **What's included:** every PR you authored that your token can see, in any repo and any state, including drafts and closed-unmerged PRs. Private repos need the `repo` scope, and SSO-protected orgs need the token authorized. A token that can't see your private repos undercounts with no error.
- **Past 1,000:** GitHub search stops at 1,000 results per query, so the app splits the month into smaller ranges and stays exact past that.
- **Contributions:** GitHub's profile-graph total for the month, which covers more than PRs.

## Refreshing

Numbers refresh every 15 minutes (configurable), once after your Mac wakes, when the day or time zone changes, and when you open the popover if they're over a minute old. Closing the popover doesn't stop a refresh that's under way.

- **Pausing:** Settings can pause automatic refresh until you resume it, for one hour, or until tomorrow's local midnight. Pauses survive relaunch; timed pauses resume automatically, including after sleep. The menu bar shows a pause marker and Settings shows the resume time. **Refresh now** still works, and an in-flight refresh finishes. A chosen resume time stays fixed if you change time zones.
- **Failures:** the last good numbers stay on screen with the error next to them. A brief GitHub or network failure is retried on the spot, and a failed scheduled refresh tries again a minute later.
- **Offline:** while your Mac is offline, the app says it's waiting for the network instead of retrying, and refreshes as soon as the connection is back. The refresh button always tries.
- **Stale numbers:** after a couple of minutes of failed refreshes, the menu bar ring and count fade until the next good one, including the "–" shown before a month's first numbers arrive. A brief failure, such as the moment after waking before Wi-Fi reconnects, leaves it alone. Open the popover to see why.
- **Rate limits:** if GitHub limits your token, the app sends nothing with that token until the limit lifts, for an hour at most, and says when that will be.
- **Relaunching:** the last good numbers are saved in `~/Library/Application Support/PR Tally/last-snapshot.json`, readable only by you, and show right away until the first refresh finishes. The file includes PR titles and repo names, and it stays when you change or clear a token.
- **A new month:** last month's numbers aren't shown as this month's. The ring empties and the popover says it's waiting for the new month's numbers, with where the old month ended. While paused, it explains how to refresh or resume instead.

## Auth

The app reads your token from `gh auth token`, looking for `gh` where Homebrew, MacPorts or Nix install it, or in `~/.local/bin`. If yours is somewhere else, save a token in settings instead; the app says when it can't find `gh`.

It checks with `gh` about once a minute, so `gh auth switch` takes effect on the next refresh after that. A failed read keeps the current token, because it may only be a brief problem, so a logout can take three refreshes to show.

To use a different account, save a token in settings; it's stored in your keychain. Use a classic token with the `repo` scope, authorized for any SSO orgs. A fine-grained token covers one account or org, so if your PRs are in private repos under more than one, counts can come up short with no error. Settings warns you when it sees one.

Saving or clearing a token refreshes with the new login right away, even while automatic refresh is paused. If a refresh was already under way, as it often is just after you open the popover, its numbers or error belong to the old login: the app drops them and fetches again, so the old account's count never shows, isn't saved, and can't send a goal notification.

A saved token always wins over `gh`. If GitHub rejects your token, the error says whether it was the saved one or your `gh` login, so when a saved token expires, save a new one or remove it; running `gh auth login` again won't help.

If a refresh fails with "GitHub returned HTTP 403:" and a message, the message is GitHub's own reason, such as an organization IP allow list or an SSO org your token isn't authorized for. If it says something other than GitHub answered, a network filter or proxy is intercepting requests to api.github.com.

## Development

```sh
./scripts/doctor.sh                       # check your setup
swift test --skip KeychainTokenTests      # run tests
swift run PopoverSnapshot out.png overview  # render the popover from fixture data
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the code layout, test patterns, every snapshot mode, and the macOS 27 toolchain fix.
