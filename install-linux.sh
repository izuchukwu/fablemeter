#!/usr/bin/env bash
# install-linux.sh — install the headless Fablemeter (fablemeter-server) on Linux.
#
# Run it AS THE USER THE AGENTS RUN AS. The daemon writes the usage snapshot to
# $HOME/.claude/fablemeter/state.json, and every agent's `fablemeter --guard`
# reads it from its own $HOME: a different user means a guard that reads a
# file nobody writes, which fails closed (exit 2) forever.
#
#   ./install-linux.sh [--data-dir DIR] [--binary PATH] [--install-swift] [--no-service]
#
#   --data-dir DIR    where account sign-ins and this machine's key live. On a
#                     Fly machine this MUST be a mounted volume (e.g. /data/fablemeter),
#                     or every restart forgets every sign-in.
#   --binary PATH     install a prebuilt fablemeter-server instead of building.
#   --install-swift   no Swift toolchain? fetch one with swiftly first (~1 GB).
#   --no-service      skip the systemd unit / supervisor, just install files.
#
# It never writes a token, never reads one, and never touches a Mac. Slack and
# the machine key are filled in afterwards (see the steps it prints).
set -euo pipefail

DATA_DIR="${FABLEMETER_DATA_DIR:-}"
BINARY=""
INSTALL_SWIFT=0
SERVICE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --install-swift) INSTALL_SWIFT=1; shift ;;
    --no-service) SERVICE=0; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

say()  { printf '==> %s\n' "$*"; }
warn() { printf '\n!!  %s\n\n' "$*" >&2; }
die()  { printf 'install-linux: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "this installer is for Linux (the Mac uses build.sh + the menu bar app)"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -n "${HOME:-}" ] || die "\$HOME is not set; run as the agents' user with a login environment"
command -v python3 >/dev/null || die "python3 is required for the fablemeter helper the agents call"

# ---- 1. data directory -------------------------------------------------------
DATA_DIR="${DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fablemeter}"
case "$DATA_DIR" in
  *"'"*|*$'\n'*) die "the data dir path may not contain a single quote or a newline: $DATA_DIR" ;;
esac
mkdir -p "$DATA_DIR"; chmod 700 "$DATA_DIR"
DATA_FS="$(df -P "$DATA_DIR" | awk 'NR==2 {print $6}')"
if [ "$DATA_FS" = "/" ]; then
  warn "The data dir $DATA_DIR is on the root filesystem. On a Fly machine that is
    wiped on every restart: sign-ins and the machine key would vanish and you would
    have to promote again. Re-run with --data-dir on a mounted volume (e.g. /data/fablemeter)."
fi
say "data dir: $DATA_DIR (mode 700)"

# ---- 2. the binary -----------------------------------------------------------
if [ -z "$BINARY" ]; then
  [ -f "$HERE/Package.swift" ] || die "run from the fablemeter repo root, or pass --binary"
  if ! command -v swift >/dev/null; then
    if [ "$INSTALL_SWIFT" = 1 ]; then
      say "installing a Swift toolchain with swiftly"
      command -v gpg >/dev/null || die "--install-swift verifies swiftly's PGP signature and needs gpg (apt-get install gnupg), or build elsewhere and pass --binary"
      tmp="$(mktemp -d)"
      url="https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
      curl -fsSL "$url" -o "$tmp/swiftly.tgz"
      curl -fsSL "$url.sig" -o "$tmp/swiftly.tgz.sig"
      # swift.org's published release keys, in a throwaway keyring so nothing
      # is added to this user's own. Refuse to run an unverified download.
      export GNUPGHOME="$tmp/gnupg"; mkdir -m 700 "$GNUPGHOME"
      curl -fsSL "https://www.swift.org/keys/all-keys.asc" | gpg --batch --quiet --import - \
        || die "could not import swift.org's signing keys"
      gpg --batch --quiet --verify "$tmp/swiftly.tgz.sig" "$tmp/swiftly.tgz" 2>/dev/null \
        || die "swiftly's signature did not verify — refusing to run it"
      unset GNUPGHOME
      say "swiftly signature verified against swift.org's keys"
      tar -xzf "$tmp/swiftly.tgz" -C "$tmp"
      "$tmp/swiftly" init --quiet-shell-followup --assume-yes
      # shellcheck disable=SC1091
      . "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
      hash -r
    else
      die "no Swift toolchain. Re-run with --install-swift, or build elsewhere and pass --binary"
    fi
  fi
  # Dynamically linked against the toolchain's Swift runtime, which is here
  # because we just built with it. (A fully static build is not an option on
  # Swift 6.4: its static FoundationNetworking archive fails to link.) So keep
  # the toolchain installed; a --binary copied from elsewhere needs the same
  # Swift runtime version on this machine.
  say "building fablemeter-server (release)"
  ( cd "$HERE" && swift build -c release --product fablemeter-server )
  BINARY="$(cd "$HERE" && swift build -c release --product fablemeter-server --show-bin-path)/fablemeter-server"
fi
[ -x "$BINARY" ] || die "no executable at $BINARY"
"$BINARY" selftest >/dev/null || die "the binary's own selftest failed; refusing to install it"

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
install -m 755 "$BINARY" "$BIN_DIR/fablemeter-server"
say "installed $BIN_DIR/fablemeter-server (selftest passed)"

# ---- 3. the agents' helper ---------------------------------------------------
mkdir -p "$HOME/.claude/bin"
install -m 755 "$HERE/scripts/fablemeter" "$HOME/.claude/bin/fablemeter"
say "installed $HOME/.claude/bin/fablemeter (the --guard the agents call)"

# ---- 4. environment file (no secrets written) --------------------------------
CONF_DIR="$HOME/.config/fablemeter"; ENV_FILE="$CONF_DIR/env"
mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
if [ ! -f "$ENV_FILE" ]; then
  umask 077
  cat > "$ENV_FILE" <<ENV
# fablemeter-server environment. Mode 600. Read by the service and the wrapper.
FABLEMETER_DATA_DIR='$DATA_DIR'
# Slack: the SERVER alone posts warnings. Fill these from your secret store —
# this installer never writes a token.
# FABLEMETER_SLACK_TOKEN=
# FABLEMETER_SLACK_CHANNEL=C0BT334MZMX
# FABLEMETER_FABLE_FIRST=1
ENV
  say "wrote $ENV_FILE (mode 600, no secrets)"
else
  say "kept existing $ENV_FILE"
fi

# ---- 5. a wrapper that loads the env -----------------------------------------
cat > "$BIN_DIR/fablemeter-serverd" <<WRAP
#!/usr/bin/env bash
# Loads $ENV_FILE and runs fablemeter-server with it. Use this for every
# command (connect, promote, status, run) so they all see the same data dir.
set -a; . "$ENV_FILE"; set +a
exec "$BIN_DIR/fablemeter-server" "\${@:-run}"
WRAP
chmod 755 "$BIN_DIR/fablemeter-serverd"
say "installed $BIN_DIR/fablemeter-serverd (env-loading wrapper)"

# ---- 6. keep it running ------------------------------------------------------
SERVICE_NOTE=""
if [ "$SERVICE" = 1 ]; then
  if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
    UNIT_DIR="$HOME/.config/systemd/user"; mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/fablemeter.service" <<UNIT
[Unit]
Description=Fablemeter headless usage server
After=network-online.target

[Service]
ExecStart=$BIN_DIR/fablemeter-serverd run
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    SERVICE_NOTE="systemd user unit installed (not started yet — promote first). Start with:
      systemctl --user enable --now fablemeter
      loginctl enable-linger \"\$USER\"   # keep it running without a login session"
  else
    SUPERVISE="$BIN_DIR/fablemeter-supervise"
    cat > "$SUPERVISE" <<SUP
#!/usr/bin/env bash
# No systemd (typical on a Fly machine). Restarts the daemon if it exits and
# logs to \$HOME/.local/state/fablemeter.log. Refuses to start a second copy:
# two copies would spend the same rotating refresh tokens.
LOG="\$HOME/.local/state/fablemeter.log"; mkdir -p "\$(dirname "\$LOG")"
LOCK="\$HOME/.local/state/fablemeter.supervise.lock"
exec 9>"\$LOCK"
flock -n 9 || { echo "fablemeter-supervise: already running" >&2; exit 1; }
while true; do
  "$BIN_DIR/fablemeter-serverd" run >>"\$LOG" 2>&1
  rc=\$?
  echo "\$(date -u +%FT%TZ) fablemeter-server exited (\$rc), restarting in 10s" >>"\$LOG"
  sleep 10
done
SUP
    chmod 755 "$SUPERVISE"
    SERVICE_NOTE="no systemd here, so installed a supervisor instead. Start it detached with:
      nohup $SUPERVISE >/dev/null 2>&1 &
    and make it start on boot however this machine starts things (on Fly: add it
    to the machine's process list / init). Logs: \$HOME/.local/state/fablemeter.log"
  fi
fi

cat <<NEXT

Installed. Next, in order:

  0. BEFORE PROMOTING ANYTHING: upgrade every existing Mac running the Fablemeter
     menu bar app to the build that shipped with this server. Once a server is
     named, the web answers pushes from an older Mac build with 409 on every push.

  1. Slack (the server posts warnings): add FABLEMETER_SLACK_TOKEN and
     FABLEMETER_SLACK_CHANNEL to $ENV_FILE from your secret store.

  2. Connect this machine to the web companion:
       $BIN_DIR/fablemeter-serverd connect
     Open the URL it prints on any device, confirm, paste the code (it lives 5 min).

  3. Make this machine the server — signs in each account HERE, one at a time:
       $BIN_DIR/fablemeter-serverd promote

  4. Start the daemon:
     $SERVICE_NOTE

  5. Check it:
       $BIN_DIR/fablemeter-serverd status
       fablemeter --guard --min-5h 10 --min-weekly 20 --account P; echo \$?

NEXT
