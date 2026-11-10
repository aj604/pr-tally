# PR Tally

A little macOS menu bar app that tracks your GitHub pull requests for the month against a goal, so you can see where you stand at a glance.

The menu bar shows a progress ring for the month next to today's count. The ring is orange when you're behind pace and green when you're on or ahead of it, with a tick where a steady pace would be today. The ring only closes once you reach the goal; until then a gap stays open at the top, even a few PRs short, and near the end of the month the pace tick sits beside the gap rather than in it. Today's number turns green once it beats the daily quota (goal ÷ days in the month). In Settings, choose **Month progress** to show the monthly count/goal instead; that number turns green when the goal is reached. Hover over the menu bar item for the numbers behind the ring: the month's count against the goal, how far ahead of or behind pace you are and the days left (or the day you hit the goal), today's count against the daily quota and how many more today needs for its share of the goal, and when the numbers were last updated. When the menu bar has faded, the hover also says why, in the same words as the popover. Click the menu bar item for:

- Progress against the goal, with a marker where a steady pace would be today
- How far ahead or behind pace you are, PRs needed per day from the start of today (so it holds steady as you work), how many more today needs ("4 more today"), and your projected month-end total
- A marker when today's count beats the daily quota (goal ÷ days in the month), even if you're still behind pace. "N more today" stays beside it while today is still short of its share of the goal
- A running total chart and daily bars (hover for any day's numbers, click one to list that day's PRs)
- With a goal of merged PRs, the merges still needed weighed against this month's PRs still open (drafts included), under the likely finish: "Merges to go: 15 · 22 still open could cover them", or "22 still open, 18 more to open" when they can't. PRs opened before this month aren't counted, and the line waits until a refresh has fetched every PR's state
- Days that beat the daily quota have green bars, with a dashed line at the quota when it fits beside them, and a count of how many days this month beat it ("Beat the daily quota on 4 of 9 days"). Today counts once it beats the quota, so a quiet morning isn't a miss
- A dated best-day shortcut, plus current and best activity streaks within the month
- Recent activity over up to seven completed days in this month, compared with the preceding seven once fourteen full days exist; today is excluded
- A dated goal-hit shortcut that lists the PRs from the day the current goal was first reached
- Your top repos (click one to list its PRs this month), plus merged PRs and total GitHub contributions. The merge funnel splits what was opened this month and hasn't merged into PRs still open (drafts included), which can yet merge, and PRs closed without merging ("30 still open · 3 closed without merging"), with the still-open ones as a lighter stretch of the bar; it leaves the split out until a refresh has fetched every PR's state. In the merge funnel, click "Opened this month" to list the PRs opened this month that haven't merged, or "N older PRs also merged" to list those merged this month that were opened before it. Click the Opened or Merged figure your goal doesn't count to list those PRs
- The PRs behind the count: **See the N PRs** lists today's or the whole month's, and clicking one opens it on GitHub. A day picked from the summary opens in the first segment, where the ‹ and › arrows (or ⌘[ and ⌘], even while typing a search) step to the day before or after, up to today; **This month** shows the whole month in one section per day, newest first, each headed with its date and count; click a day's header to show only that day, or click the day segment to return to the day it last showed. A repo picked from the summary opens already chosen in the repository menu; choose **All repositories** to go back to the whole list

In the PR list, the menu at the start of the day row switches between the PRs **Opened** and **Merged**, with each one's count for the day, repository and status showing; the day, repository, status and search stay as they were, and a merge-funnel part (which belongs to one of the two) is dropped. Choose a repository or a status (open, draft, needs review, CI failing and so on), or search titles and repository names. The status menu also holds the merge-funnel parts: **Not merged** in the opened list and **Older PRs** (opened before this month) in the merged list, offered whenever they would narrow the list. A part clicked in the summary's merge funnel opens already chosen there; choose **All statuses** to go back to the whole list. Use `#123`, `owner/repository#123`, or a pasted PR URL for exact lookup. The search field says how many PRs the list holds ("Search 5 PRs opened"), and while you type, how many match ("2 of 5"). Search stays within the selected day, repository, status, metric, and merge-funnel filters. A PR that has merged says how long it took from opening, in either list ("Merged in 5h", or "25m" or "3d"), and one still open or in draft says how long it has been waiting ("Open for 3d", "Draft for 5h"). Once the list holds two PRs that have merged or are still open, the sort button (↑↓) beside the search field offers **Slowest to merge**, which puts the PRs that took longest at the top; a PR still open ranks by how long it has waited so far, so one open for 6 days sits above one merged in 2, and closed PRs go below them all. The whole month then lists as one ranking, each row with its date, instead of by day. Choose **Newest first** to go back. **Copy link** beside a PR copies its URL; the clipboard button at the end of the search field copies every matching URL, one per line in list order, including rows beyond the scroll viewport.

Opened and merged PRs each keep their own monthly goal. Switch metrics in Settings to edit the matching target; the planning preview shows its daily average, remaining PRs, and how many more are needed today. Once this month's numbers are in, it also compares the goal you're typing with your pace so far: "On track" when that pace ends the month at or past the goal, or "Short of the goal" with how many a day reaching it takes for the days left. After the first week, **Set goal to N** sets the goal to where this month's pace ends, to raise a goal you're beating or lower one you can't reach. Existing installations start both targets at the previously saved goal.

The popover always reopens on the numbers, even if you closed it on the list or in settings.

You also get a notification when a refresh takes you past your goal. macOS asks for permission the first time, and you can turn it off in Settings. A goal already met the first time the app sees that month's numbers doesn't notify. Each target (month, metric, and goal value) is announced at most once, so a raised goal or the other metric can notify when a later refresh crosses it.

## Zooming in

When the PR list opens on part of the month (a day from the charts or the goal-hit shortcut, a repo from the top repos, a part of the merge funnel, or the figure your goal doesn't count), a heading above the list names that slice and says what it amounts to:

- For a day: how many PRs it had against an average of the month's finished days ("4 opened · 1.8× an average day's 2.2", "under an average day's 5.6"). Today isn't over, so it's held to what an average day had by the same time ("2 merged so far · about an average day's 2.3 by 9:00 AM") rather than to whole days. The time is when the numbers were last fetched, not the clock, so while refresh is paused or you're offline the comparison stays where the count stopped; if they haven't been fetched since yesterday, the heading says today isn't counted yet rather than comparing an empty day. The figure your goal doesn't count opens on today when today has any, and its heading then says so ("Merged today") and describes today's PRs rather than the month's.
- Otherwise: its share of the month ("18 of 45 opened this month · 40%")
- How many of its PRs merged and the median time from opening to merging, against the month's median when the slice is part of the month ("13 merged in a median 16h · 2.6× the month's 6h", "faster than the month's 6h"), plus how many are still open, drafts, or closed without merging, and how long the oldest open one has waited ("2 open, oldest 6.1 days"; drafts don't count, since they wait on you)
- How big its PRs run: the median lines changed (added plus deleted), against the month's median when the slice is part of the month ("Median 270 lines changed · 2.6× the month's 103")
- Which repos the PRs are in, unless you zoomed to one

The heading opens folded to its first line, so the list starts near the top; "3 more" beside that line shows the rest, and "Less" folds it again. Once opened it stays open as you step between slices and zoom into others, until you fold it.

The popover widens while the PR list is open, zoomed or not, so titles and the heading's lines wrap less; it returns to its usual width when you go back to the month or open settings.

Zoomed to a repo or a part of the merge funnel, the arrows beside the heading step to the one beside it without going back to the month: the next or previous repo in the top repos' order (every repo with PRs in the count, not just the five shown, with "2 of 6" saying where you are), or the other part of the funnel. Stepping reopens the list on the new slice, clearing its search and filters.

Open, draft and closed are only counted for PRs whose state GitHub reported, and size only for PRs counted since PR Tally started fetching it (the next refresh fills it in). The heading describes the slice you opened; filters you change inside the list don't change it.

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
- **Likely finish:** the chart's range for where the month ends rates weekdays and weekends apart once a weekend has passed, so quiet weekends don't make it wider or carry five weekdays' rate across the weekends to come. Before the month's first weekend, it allows for that weekend being anywhere from as busy as the weekdays to empty. It always includes the **On track for** figure, which still extends one rate across every day.

## Refreshing

Numbers refresh every 15 minutes (configurable), once after your Mac wakes, when the day or time zone changes, and when you open the popover if they're over a minute old. Closing the popover doesn't stop a refresh that's under way.

- **Pausing:** Settings can pause automatic refresh until you resume it, for one hour, or until tomorrow's local midnight. Pauses survive relaunch; timed pauses resume automatically, including after sleep. The menu bar shows a pause marker and Settings shows the resume time. **Refresh now** still works, and an in-flight refresh finishes. A chosen resume time stays fixed if you change time zones.
- **Failures:** the last good numbers stay on screen with the error next to them. A brief GitHub or network failure is retried on the spot, and a failed scheduled refresh tries again a minute later.
- **Offline:** while your Mac is offline, the app says it's waiting for the network instead of retrying, and refreshes as soon as the connection is back. The refresh button always tries.
- **Stale numbers:** after a couple of minutes of failed refreshes, the menu bar ring and count fade until the next good one, including the "–" shown before a month's first numbers arrive. A brief failure, such as the moment after waking before Wi-Fi reconnects, leaves it alone. Hover over the faded item, or open the popover, to see why.
- **Rate limits:** if GitHub limits your token, the app sends nothing with that token until the limit lifts, for an hour at most, and says when that will be.
- **Relaunching:** the last good numbers are saved in `~/Library/Application Support/PR Tally/last-snapshot.json`, readable only by you, and show right away until the first refresh finishes. The file includes PR titles and repo names, and it stays when you change or clear a token.
- **A new month:** last month's numbers aren't shown as this month's. The ring empties and the popover says it's waiting for the new month's numbers, with where the old month ended. While paused, it explains how to refresh or resume instead.

## Auth

The app reads your token from `gh auth token`, looking for `gh` where Homebrew, MacPorts or Nix install it, or in `~/.local/bin`. If yours is somewhere else, save a token in settings instead; the app says when it can't find `gh`.

It checks with `gh` about once a minute, so `gh auth switch` takes effect on the next refresh after that. A failed read keeps the current token, because it may only be a brief problem, so a logout can take three refreshes to show.

To use a different account, save a token in settings; it's stored in your keychain. Use a classic token with the `repo` scope, authorized for any SSO orgs. A fine-grained token covers one account or org, so if your PRs are in private repos under more than one, counts can come up short with no error. Settings warns you when it sees one.

A classic token without the `repo` scope (only `public_repo`, say, or no scopes at all) works, but GitHub's search quietly leaves out every private repo, so the count comes up short with no error. Each time you open settings with a token saved, and when you save one, the app asks GitHub which scopes the token has. If `repo` isn't among them, the login line turns orange and says it's counting only PRs in public repos. Adding `repo` to the same token on GitHub clears the warning the next time you open settings. If GitHub can't be reached, or your token is rate limited, the last answer stands: like a refresh, the check sends nothing with a limited token. A `gh` login has `repo` unless you removed it, and fine-grained tokens have no scopes to check.

The same check catches the other silent shortfall: an organization that uses SAML single sign-on hides its repos from a classic token until you authorize the token for it, and search leaves its PRs out without an error. The check searches for your own PRs the way a refresh does, and when GitHub says it left organizations out, the login line turns orange and says how many ("Counting PRs for @you, but not in 2 organizations that use SSO"). To fix it, find the token on GitHub under Settings > Developer settings > Personal access tokens, choose Configure SSO, and authorize each one; the warning clears the next time you open settings. Only a saved token is checked, not a `gh` login.

Saving or clearing a token refreshes with the new login right away, even while automatic refresh is paused. If a refresh was already under way, as it often is just after you open the popover, its numbers or error belong to the old login: the app drops them and fetches again, so the old account's count never shows, isn't saved, and can't send a goal notification.

Settings says which account the numbers are counted for, such as "Counting PRs for @you with your gh login". After you save or clear a token it says it's checking, then names the new account once GitHub answers. If GitHub rejects the login, `gh` isn't logged in, or `gh` can't be found, it says so there in orange, with what to do, instead of naming a login that isn't working. That warning stays while you're offline and after a relaunch, until a refresh succeeds or you change the token. If the check can't reach GitHub, such as while offline, it says the login isn't checked yet rather than naming the previous account, whose numbers stay on screen until a refresh succeeds. That holds after a relaunch too.

A saved token always wins over `gh`. If GitHub rejects your token, the error says whether it was the saved one or your `gh` login, so when a saved token expires, save a new one or remove it; running `gh auth login` again won't help.

If a refresh fails with "GitHub returned HTTP 403:" and a message, the message is GitHub's own reason, such as an organization IP allow list or an SSO org your token isn't authorized for. If it says something other than GitHub answered, a network filter or proxy is intercepting requests to api.github.com.

## Development

```sh
./scripts/doctor.sh                       # check your setup
swift test --skip KeychainTokenTests      # run tests
swift run PopoverSnapshot out.png overview  # render the popover from fixture data
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the code layout, test patterns, every snapshot mode, and the macOS 27 toolchain fix.
