# Fablemeter

A macOS menu bar app that tracks the 5-hour, weekly, and Fable weekly usage
windows for up to three Claude accounts at once.

Each account is one thin vertical gauge with a single-character label under it.
The gauge shows **headroom** — how much room is left before the tightest of the
three windows blocks you:

```
headroom = min(100 − 5-hour%, 100 − weekly%, 100 − Fable weekly%)
```

Monochrome above 25% headroom, orange at or below 25%, red at or below 10%.
An account with no headroom left dims its letter and empties its gauge.
Click the gauges for per-window percentages and reset countdowns.

## Fable

Once an account's Fable week is spent, Fable stops being a limit worth measuring
and drops out of the minimum:

```
headroom = min(100 − 5-hour%, 100 − weekly%)
```

and the letter turns yellow to say so. Yellow is not a warning — the gauge keeps
its own orange and red tiers, computed from whichever headroom is in effect —
it is the answer to "what is this gauge measuring?". White means every window
counts; yellow means Fable is gone and what is left is the non-Fable headroom.
An account whose letter is yellow can still be perfectly usable, and reads
`Available` in the popover rather than `Blocked`.

Spent means the Fable bucket is **there and at 100%**. The API nulls these keys
routinely, and a bucket it did not report is unknown rather than spent, so it
keeps the ordinary white treatment. The state is per account and flips back on
its own the moment Fable resets.

A yellow letter still dims when its account is out of everything else, so
Fable-spent *and* blocked is a dimmed yellow: colour says what is measured,
dimming says whether the account can be used at all.

The yellow follows the menu bar's appearance the same way the letters
themselves do. `systemYellow` is a fill colour: an 8pt glyph drawn in it
measures 11.7:1 against a dark menu bar but 1.3:1 against a light one, which is
not a signal. So a dark bar gets `systemYellow` and a light bar gets a darker
yellow of the same hue, at 4.1:1. `--selftest` measures both.

## Readings, zeros and nothing

The API sends each window's percent as a number or as `null`, and the two are
different facts kept apart end to end:

| The server said | headroom | Gauge | Row | Verdict |
| --- | --- | --- | --- | --- |
| `74` | counts | painted, level | `74%` + reset | Available / Limited / … |
| `0` | counts as a whole window | painted, full | `0%` + `—` | Available |
| `null` | skipped | — | `—` + `—` | — |
| nothing at all | nothing resolves | hollow, empty | dashes | No data |

A reported zero means the window is untouched, which is the *best* possible
reading, not a missing one — an account that has simply not been used reads
`Available`. Only a payload with no readings in it at all resolves to `No data`,
and it is called that rather than "Unknown" because every other word in that slot
names something to act on or wait out.

The menu bar track carries the same distinction on its own axis:

```
painted + level   live data
painted + empty   blocked, and the server said so
outline + level   stale — the last reading, no longer refreshing
outline + empty   no reading
```

## Polling

Each account is fetched once every **5 minutes**, and the accounts in a cycle
are spaced a couple of seconds apart rather than fired together. A 5-hour window
moves about 1% every three minutes, so polling faster buys no new information
and only spends request budget against an endpoint that rate limits.

Opening the popover or waking from sleep only refetches if the reading on screen
is more than 60 seconds old. Manual refresh ignores that, but nothing ignores
backoff.

On failure each account backs off on its own: an HTTP 429 waits 5, 10, 20, 40
minutes and then holds at 45, with ±15% jitter so several accounts that failed
together don't return in lockstep. A `Retry-After` header wins over that
schedule, though it can never pull the next attempt in front of the ordinary
5-minute interval. Other failures — 5xx, timeouts, offline — back off on the
same curve from 1 minute, capped at 15. The first success clears it all.

A failed fetch never blanks the display: the last reading stays on screen inside
a hollow gauge, which is what tells you it is no longer live.

## Build

```sh
./build.sh          # swift build -c release + "dist/Fablemeter.app"
open "dist/Fablemeter.app"
```

Swift 5.9+, macOS 14+, no third-party dependencies, no Xcode project.

## Accounts

Click **Add Account…** in the popover. This runs its own OAuth PKCE flow in your
browser; it never touches Claude Code's own credentials, so signing in here does
not sign you out of the CLI. Up to three accounts.

Click an account's character token to change it. Double-click the name to rename
it. Right-click a row for Reconnect Account / Set Label / Rename / Move Up /
Move Down / Sign Out. **Reconnect Account…** runs the OAuth flow again and
replaces that account's credential in place, keeping its name, label and
position. It is offered on every account, not only a rejected one, which is also
the **Reconnect** shown in place of the verdict when a credential has died.

Drag an account block to reorder it. The menu bar draws the accounts in the
popover's order, left to right, and rearranges as the drag crosses each row.
The order is the order of the array in `accounts.json`, so it survives a
relaunch without a separate index to keep in sync.

## Warnings

Crossing 75%, 90% or 95%, and burning through the 5-hour window too fast, each
raise one warning per window. A warning goes to two places: the macOS
notification center, and, when `slack.json` is present, a Slack channel. Slack
is a second destination rather than a fallback, so a run that cannot notify —
notification rights denied, or an unbundled `swift run` — still posts.

## Storage

Accounts live in `~/Library/Application Support/ClaudeUsageBar/accounts.json`
(directory 0700, file 0600). That directory keeps the old name on purpose, and
keeps it through every rename of the app: it is invisible to the user, it holds
the only copy of each account's refresh token, and those tokens are single-use
and rotate — so a migration that dropped the file would orphan the accounts with
nothing left to recover them from. `--selftest` pins the path so it cannot drift
by accident. Refresh tokens are stored there in plaintext rather
than the Keychain: the app is ad-hoc signed, so every rebuild changes its
signature and macOS would prompt for Keychain access on each launch.

Slack mirroring reads `~/Library/Application Support/ClaudeUsageBar/slack.json`
(same directory, also 0600), shaped `{"token": "...", "channel": "C..."}`. The
token is a Slack bot token, so it is a credential and is never logged or
printed. The file is optional: absent or unreadable, mirroring is simply off
and the app says so once in the log, the same way a denied notification does.
It is re-read per warning, so dropping it in or taking it away takes effect
without a relaunch.

## Flags

| Flag | What it does |
| --- | --- |
| `--selftest` | Decodes an embedded usage fixture, walks the polling and backoff schedules, and exercises token rotation — single-flight refresh, persist-before-return, and the terminal `needs sign-in` state — with no network. Also runs the callback-loop checks below, so consecutive reconnects stay covered. |
| `--callback-loop [cycles] [delayMs]` | Runs the sign-in's loopback listener over and over in one process — bind, receive the redirect, tear down — plus an abandoned flow that never gets a redirect. No browser, no credentials. This is the second reconnect in a session, on its own. |
| `--slack-test` | Posts one line to the Slack channel in `slack.json` and exits 0 if Slack took it, 1 if there is no readable config or the post was refused. Proves the mirror without waiting for a real threshold to be crossed. |
| `--probe` | Reads Claude Code's existing access token read-only and prints live parsed buckets. Never writes or refreshes it. |
| (always on) | Every successful poll writes one line to the unified log describing the shape of what it decoded — which `kind`s came back, each reading as a number or `null`, whether a reset window was present, and the headroom it resolved to. Read it with `log show --predicate 'subsystem == "com.izu.fablemeter"' --last 30m`. It names the account by its menu bar letter and nothing else; no part of `accounts.json` and no credential goes near it. |
| `--demo` | Eight fake in-memory accounts, for looking at the drawing: blocked, rate limited, healthy, one whose credential the server has rejected, one with Fable spent, one with Fable spent *and* nothing else left, one the server reports as untouched (`0%` everywhere, Available), and one the server reports nothing about (dashes everywhere, No data). |
| `--render-popover <dir>` | Writes the popover itself in both appearances, without a menu bar or a click. |
| `--render <dir>` | Writes the menu bar image for every state in both appearances. The real menu bar takes its appearance from the desktop picture behind it, so a dark wallpaper otherwise makes the light case impossible to see on screen. |

## Caveat

`https://api.anthropic.com/api/oauth/usage` is undocumented and its key set
changes without notice; parsing is deliberately defensive and unknown keys are
ignored, but the app can still go blank if the shape changes enough.

## History note

On 2026-08-22 this repository's git history was rewritten to replace the
captured fixture's internal bucket names with placeholders (`bucket_a`…`bucket_f`).
No credential, key, or token was ever committed to this repository — verified
against every blob and commit message in the pre-rewrite history before this
sentence was written. Nothing else changed.
