# Installing the Fablemeter server on Linux

`fablemeter-server` is Fablemeter without the menu bar. One machine per owner is
the **server**: it polls Anthropic for every account, posts usage warnings to
Slack, and pushes the numbers to the web companion. Every other machine (the
Macs) is a **follower** that reads the server's numbers from the web and never
polls Anthropic itself. The server also writes `~/.claude/fablemeter/state.json`,
which is what agents on this machine read with `fablemeter --guard`.

## Rules — read before doing anything

1. **Upgrade every Mac first.** Once any machine is promoted, the web answers a
   push from an *older* Mac build with `409` on every push. Install the new menu
   bar app on each Mac before running `promote` here.
2. **Never copy a sign-in between machines.** Do not copy `accounts.json`, a
   refresh token, or the data directory from a Mac or another server. Refresh
   tokens are single-use and rotate; two machines spending one token destroys
   it. `promote` signs each account in *here*, fresh, which is the only safe way.
3. **Never run two copies.** One daemon per data directory. The supervisor
   refuses a second copy; do not start `fablemeter-server run` by hand beside it.
4. **Run everything as the user the agents run as.** The state file lands in
   that user's `$HOME`; a different user means `fablemeter --guard` reads a file
   nobody writes and fails closed (exit 2) forever.
5. **Put the data directory on a persistent volume.** On Fly, the root
   filesystem is wiped on restart; sign-ins would vanish. The machine id and
   the remembered role live there too, so a restart keeps this machine's
   identity and its server role.
6. **Promote only while the daemon is stopped.** `promote` rewrites the account
   store and refuses to run while `fablemeter-server run` holds the data
   directory. To re-promote later: stop the daemon, `promote`, start it again.

## Prerequisites

- Linux, `git`, `python3`, `curl`
- A Swift toolchain — or pass `--install-swift` and the installer fetches one
  with swiftly (~1 GB, one time). That also needs `gpg`: the installer verifies
  swiftly's PGP signature against swift.org's published keys and refuses to run
  it otherwise. Keep the toolchain installed afterwards: the binary links the
  Swift runtime from it.
- A mounted volume for data, e.g. `/data` on Fly
- An interactive terminal for `connect` and `promote` (`fly ssh console` works):
  each asks you to open a URL on any device and paste back a code

## Install

```sh
git clone https://github.com/izuchukwu/fablemeter.git ~/fablemeter
cd ~/fablemeter
./install-linux.sh --data-dir /data/fablemeter            # add --install-swift if `swift` is missing
```

It builds the release binary, **refuses to install it if its own selftest
fails**, and installs:

> Building by hand: always `swift build -c release --product fablemeter-server`.
> A bare `swift build` fails on Linux with `no such module 'AppKit'`, because
> the package also holds the macOS menu bar app. That error is expected and
> says nothing about the server; the installer already passes `--product`.

| Path | What |
| --- | --- |
| `~/.local/bin/fablemeter-server` | the daemon + CLI |
| `~/.local/bin/fablemeter-serverd` | wrapper that loads the env file — use this for every command |
| `~/.local/bin/fablemeter-supervise` | restart loop, installed when there is no systemd (Fly) |
| `~/.config/systemd/user/fablemeter.service` | instead of the above, when systemd is available |
| `~/.claude/bin/fablemeter` | the reader agents call (`--guard`, `--json`) |
| `~/.config/fablemeter/env` | settings, mode 600, **no secrets written by the installer** |

## Configure, connect, promote, start

```sh
# 1. Slack — the server alone posts warnings. Add from your secret store:
#      FABLEMETER_SLACK_TOKEN=xoxb-…
#      FABLEMETER_SLACK_CHANNEL=C0BT334MZMX
$EDITOR ~/.config/fablemeter/env

# 2. Give this machine a key for the web companion.
#    Open the printed URL on any device, sign in, confirm, paste the code (valid 5 min).
~/.local/bin/fablemeter-serverd connect

# 3. Become the server. Signs in each account on THIS machine, one at a time:
#    open the printed URL, approve, paste the code. Type `skip` to leave one out.
#    Labels and nicknames: for each account, promote offers the name the CURRENT
#    server already uses (matched by the Anthropic account id, not by guess), so
#    accept the defaults to keep P Personal / C Charm / I Iconic — the letters
#    agents pass as `--account`. If the web has no names to offer, type them:
#    P Personal, C Charm, I Iconic. Duplicate labels are refused.
~/.local/bin/fablemeter-serverd promote

# 4. Start it.
nohup ~/.local/bin/fablemeter-supervise >/dev/null 2>&1 &     # Fly / no systemd
#   — or —
systemctl --user enable --now fablemeter && loginctl enable-linger "$USER"
```

On Fly, also make `fablemeter-supervise` start on boot (the machine's process
list / init), or it stops at the next restart.

## Verify

```sh
~/.local/bin/fablemeter-serverd status        # role should read: SERVER (this machine)
tail ~/.local/state/fablemeter.log            # supervisor log: "role: server", then usage lines
fablemeter                                    # one line per account
fablemeter --guard --min-5h 10 --min-weekly 20 --account P; echo $?   # 0 clear, 1 below floor, 2 cannot tell
```

The first usage lines arrive within one poll cycle (up to ~5 minutes).

## Settings (`~/.config/fablemeter/env`)

| Variable | Meaning |
| --- | --- |
| `FABLEMETER_DATA_DIR` | sign-ins, web key, machine id, remembered role, account ids (mode 700). Must be persistent. Commands run without the wrapper read it from this file too, so every command uses the same directory. |
| `FABLEMETER_SLACK_TOKEN`, `FABLEMETER_SLACK_CHANNEL` | Slack warnings (server only) |
| `FABLEMETER_SLACK_CONFIG` | alternatively, a path to `{"token":…,"channel":…}` |
| `FABLEMETER_FABLE_FIRST=0` | measure `min(5-hour, weekly)` and ignore Fable |
| `FABLEMETER_WARN_75/90/95=0`, `FABLEMETER_WARN_FAST_BURN=0` | silence a warning |

## Troubleshooting

| Symptom | Meaning / fix |
| --- | --- |
| `web not connected` | run `connect` |
| log: `machine key rejected` | the key was revoked on the web; run `connect` again |
| log: `role: follower` | another machine is the server. To take over, run `promote` here |
| log: `needs sign-in` | that account's sign-in is dead; run `promote` again |
| guard exits 2 | no/stale state file, a null reading, or unknown active account — pass `--account` |
| guard exits 2 on a follower | the active account is matched by Anthropic account id; the server's rows carry none (an older server build, or its profile lookup failed) or this machine is signed into an account the server does not track — pass `--account` |
| `promote`: "that was X, not Y" | the browser was still signed into another account. The row keeps its sign-in; sign out of X in the browser and run `promote` again |
| bare `swift build` fails with `no such module 'AppKit'` | expected on Linux; build with `--product fablemeter-server` |
| `promote`: "the daemon is running" | stop it (`systemctl --user stop fablemeter`, or kill `fablemeter-supervise`), promote, start it again |
| a Mac's gauges read "Following server" | expected once this machine is promoted: that Mac stopped polling |

## What it never does

Never prints, logs or writes a token outside the data directory; never writes
an email into the state file; never polls Anthropic while another machine is
the server; never promotes itself — only `promote`, run by a person here, does.
The follower check hits `/api/state` every 30 s (120/hr, under the web's 600/hr
per-key cap); do not lower it. A server asks it before every poll pass as well
("am I still the server?"), reusing any answer under 30 s old, so it stays near
60–70 reads/hr.
