# Claude Usage Bar

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
./build.sh          # swift build -c release + dist/ClaudeUsageBar.app
open dist/ClaudeUsageBar.app
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

## Storage

Accounts live in `~/Library/Application Support/ClaudeUsageBar/accounts.json`
(directory 0700, file 0600). Refresh tokens are stored there in plaintext rather
than the Keychain: the app is ad-hoc signed, so every rebuild changes its
signature and macOS would prompt for Keychain access on each launch.

## Flags

| Flag | What it does |
| --- | --- |
| `--selftest` | Decodes an embedded usage fixture, walks the polling and backoff schedules, and exercises token rotation — single-flight refresh, persist-before-return, and the terminal `needs sign-in` state — with no network. |
| `--probe` | Reads Claude Code's existing access token read-only and prints live parsed buckets. Never writes or refreshes it. |
| `--demo` | Four fake in-memory accounts, for looking at the drawing: blocked, rate limited, healthy, and one whose credential the server has rejected. |
| `--render-popover <dir>` | Writes the popover itself in both appearances, without a menu bar or a click. |
| `--render <dir>` | Writes the menu bar image for every state in both appearances. The real menu bar takes its appearance from the desktop picture behind it, so a dark wallpaper otherwise makes the light case impossible to see on screen. |

## Caveat

`https://api.anthropic.com/api/oauth/usage` is undocumented and its key set
changes without notice; parsing is deliberately defensive and unknown keys are
ignored, but the app can still go blank if the shape changes enough.
