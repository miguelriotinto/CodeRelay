#!/bin/zsh
# Upgrade and restart the Homebrew Mac server from OUTSIDE the relay.
#
#   Scripts/mac-server-upgrade.sh          start the upgrade as a one-shot launchd job
#   Scripts/mac-server-upgrade.sh --run    (launchd only) do the upgrade
#
# Why launchd: `brew upgrade coderelay` stops the running service, and the relay
# kills every process in each PTY's session on shutdown. Run from a shell the
# relay hosts, brew itself is killed after pouring the bottle but before linking
# bin/ and restarting the service — dangling `claude-relay*` links, relay down
# (v0.3.42, 2026-11-04). A launchd job is in no PTY session, so it survives.
#
# Progress and the verdict go to $LOG; the last line is `=== <date> end: OK`
# or `end: FAILED (<reason>)`. A shell inside the relay is killed when the relay
# restarts — read the log from a new session.
set -u
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
LABEL=com.claude.relay.upgrade
DIR=$HOME/.claude-relay/upgrade
LOG=$DIR/upgrade.log
PLIST=$DIR/$LABEL.plist
DOMAIN=gui/$(id -u)

if [[ ${1:-} != --run ]]; then
  mkdir -p "$DIR"
  if JOB=$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null); then
    if print -r -- "$JOB" | grep -q 'pid = '; then
      echo "An upgrade is already running; see $LOG" >&2
      exit 1
    fi
    launchctl bootout "$DOMAIN/$LABEL"   # a run that died before cleaning up
  fi
  # Run a copy: the job must not depend on the checkout staying put.
  cp "$0" "$DIR/mac-server-upgrade.sh" && chmod 755 "$DIR/mac-server-upgrade.sh"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DIR/mac-server-upgrade.sh</string><string>--run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  : >"$LOG"
  launchctl bootstrap "$DOMAIN" "$PLIST" || { echo "launchctl bootstrap failed" >&2; exit 1; }
  echo "Upgrade started as launchd job $LABEL; log: $LOG"
  [[ -n ${CLAUDE_RELAY_SESSION_ID:-} ]] &&
    echo "This shell runs inside the relay and ends when it restarts; check $LOG from a new session."
  exit 0
fi

echo "=== $(date) start"
finish() {
  echo "--- verify"
  claude-relay status
  ls -l /opt/homebrew/bin/claude-relay /opt/homebrew/bin/claude-relay-server
  echo "=== $(date) end: $1"
  rm -f "$PLIST"
  launchctl bootout "$DOMAIN/$LABEL"   # ends this process; keep it last
  exit 0
}

brew update -q
brew upgrade coderelay || echo "!!! brew upgrade failed; relinking and restarting the installed keg anyway"
# Link and start unconditionally: whatever brew left behind, the bin/ links
# must point at the installed keg and the service must come back up.
brew link --overwrite coderelay
brew services restart coderelay || finish "FAILED (brew services restart)"
for _ in {1..10}; do
  sleep 2
  claude-relay health >/dev/null 2>&1 && finish OK
done
finish "FAILED (health check)"
