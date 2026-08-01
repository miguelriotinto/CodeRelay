# CodeRelay state hook (F6 — hook-based state authority)

`claude-relay-state-hook.sh` lets Claude Code report its **authoritative**
lifecycle state (working / blocked / idle) to the CodeRelay server, instead of
the server inferring state by scraping the terminal screen.

## Why

CodeRelay's server classifies agent state from the emulated terminal screen,
defended against flicker by anti-flap heuristics (startup grace, pending-idle
hold). That works with no setup, but has inherent lag and can occasionally
misread unusual screens. When this hook is installed, Claude Code tells the
server exactly when it starts working, blocks on input, or finishes — so state
is immediate and accurate.

**Fully optional and safe.** If the hook is absent, stops firing, or you use an
agent that doesn't support it, the server silently falls back to screen
detection. Hook state is only trusted while *fresh* (a 10-second window); once
stale, screen detection resumes automatically.

## How it works

The server injects two environment variables into every session's shell:

| Variable                  | Value                                    |
| ------------------------- | ---------------------------------------- |
| `CLAUDE_RELAY_SESSION_ID` | the session UUID                         |
| `CLAUDE_RELAY_ADMIN_PORT` | the localhost admin port to POST state to |

On each Claude Code lifecycle event, the hook maps the event to a state and
POSTs `{"sessionId": ..., "state": ...}` to
`http://127.0.0.1:$CLAUDE_RELAY_ADMIN_PORT/hook/state`. The admin server binds
`127.0.0.1` only, so this never leaves the machine — the same trust boundary as
every other admin endpoint.

Event → state mapping:

| Claude Code event                       | Reported state |
| --------------------------------------- | -------------- |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | `working`  |
| `Notification`                          | `blocked`      |
| `Stop`, `SubagentStop`                  | `idle`         |

The hook reports **state only** — the server still owns agent *identity* via
process detection, so the hook can never mislabel which agent is running.

## Install

```sh
claude-relay hook install
```

That copies the script to `~/.claude-relay/hooks/`, makes it executable, backs up
`~/.claude/settings.json`, and registers the four lifecycle events — adding only
what is missing, so it is safe to re-run and never clobbers hooks you already
have. Use `--dry-run` to preview, and `claude-relay hook uninstall` to reverse it.

<details>
<summary>Manual install (if you prefer to edit settings.json yourself)</summary>

Copy the script somewhere stable and mark it executable:

```sh
mkdir -p ~/.claude-relay/hooks
cp Scripts/hooks/claude-relay-state-hook.sh ~/.claude-relay/hooks/
chmod +x ~/.claude-relay/hooks/claude-relay-state-hook.sh
```

Then register it for the relevant events in Claude Code's settings
(`~/.claude/settings.json`). Claude Code passes the event name as the first
argument; the hook derives the state from it:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "~/.claude-relay/hooks/claude-relay-state-hook.sh UserPromptSubmit" }] }
    ],
    "PreToolUse": [
      { "hooks": [{ "type": "command", "command": "~/.claude-relay/hooks/claude-relay-state-hook.sh PreToolUse" }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "~/.claude-relay/hooks/claude-relay-state-hook.sh Notification" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.claude-relay/hooks/claude-relay-state-hook.sh Stop" }] }
    ]
  }
}
```

The hook is a no-op outside a CodeRelay session (the env vars are absent), so
this configuration is harmless when you run Claude Code locally.

</details>

## Verify

With the hook installed, start a session through CodeRelay and drive Claude Code
to a permission prompt — the client should reflect `blocked` immediately, with
no screen-detection delay. Uninstall the hook and behavior is identical to
before F6.
