#!/bin/sh
# claude-relay-state-hook.sh — report Claude Code lifecycle state to CodeRelay (F6).
#
# CodeRelay's server normally infers agent state by scraping the terminal screen,
# which is defended against flicker by anti-flap heuristics. When this hook is
# installed, Claude Code reports its *authoritative* lifecycle state directly, so
# blocked/working/idle reflect reality without the screen-detection lag. If the
# hook is absent or stops reporting, the server silently falls back to screen
# detection — nothing breaks.
#
# The server injects two env vars into every session's shell:
#   CLAUDE_RELAY_SESSION_ID   the session UUID
#   CLAUDE_RELAY_ADMIN_PORT   the localhost admin port to POST to
# This hook maps the invoking Claude Code hook event to a state and POSTs it to
#   http://127.0.0.1:$CLAUDE_RELAY_ADMIN_PORT/hook/state
#
# STATE ONLY: the server owns agent *identity* via process detection; this hook
# never asserts which agent is running, only what state it's in.
#
# Install: see Scripts/hooks/README.md. The event name is passed as $1 (or via
# the CLAUDE_HOOK_EVENT env var); state defaults are derived from it.

set -eu

# No relay session context → not running inside a CodeRelay PTY; do nothing.
[ -n "${CLAUDE_RELAY_SESSION_ID:-}" ] || exit 0
[ -n "${CLAUDE_RELAY_ADMIN_PORT:-}" ] || exit 0

# Resolve the event name: first arg, else $CLAUDE_HOOK_EVENT.
event="${1:-${CLAUDE_HOOK_EVENT:-}}"

# Map Claude Code lifecycle events → CodeRelay state.
#   UserPromptSubmit / PreToolUse / PostToolUse → working (agent is doing work)
#   Notification                                → blocked (needs the user's input)
#   Stop / SubagentStop                         → idle    (turn finished)
case "$event" in
  UserPromptSubmit|PreToolUse|PostToolUse) state="working" ;;
  Notification)                            state="blocked" ;;
  Stop|SubagentStop)                       state="idle" ;;
  *)
    # Unknown event: nothing to report. Exit success so we never block Claude Code.
    exit 0
    ;;
esac

url="http://127.0.0.1:${CLAUDE_RELAY_ADMIN_PORT}/hook/state"
payload="{\"sessionId\":\"${CLAUDE_RELAY_SESSION_ID}\",\"state\":\"${state}\"}"

# Best-effort, fully non-blocking: short timeouts, silent, never fail the hook.
# A hook that errors or hangs must never disrupt the agent it's observing.
curl -s -m 2 -X POST -H 'Content-Type: application/json' \
  -d "$payload" "$url" >/dev/null 2>&1 || true

exit 0
