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
Click the gauges for per-window percentages and reset countdowns.

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
it. Right-click a row for Set Label / Rename / Remove.

## Storage

Accounts live in `~/Library/Application Support/ClaudeUsageBar/accounts.json`
(directory 0700, file 0600). Refresh tokens are stored there in plaintext rather
than the Keychain: the app is ad-hoc signed, so every rebuild changes its
signature and macOS would prompt for Keychain access on each launch.

## Flags

| Flag | What it does |
| --- | --- |
| `--selftest` | Decodes an embedded usage fixture and asserts the parsed values. |
| `--probe` | Reads Claude Code's existing access token read-only and prints live parsed buckets. Never writes or refreshes it. |
| `--demo` | Three fake in-memory accounts, for looking at the drawing. |

## Caveat

`https://api.anthropic.com/api/oauth/usage` is undocumented and its key set
changes without notice; parsing is deliberately defensive and unknown keys are
ignored, but the app can still go blank if the shape changes enough.
