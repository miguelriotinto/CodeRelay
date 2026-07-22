# Session State Indicators Redesign — Design

**Date:** 2026-07-22
**Scope:** iOS, macOS, and Android clients. No server or wire-protocol changes.

## Goal

Redesign how a session's lifecycle state and coding-agent state are shown, so
the two concepts are visually separated and consistent across all three clients:

- **Left of the session name:** a color-coded dot for the *attachment/lifecycle*
  state (replaces the current text pill like "active-attached").
- **Right of the session name:** the friendly *coding-agent name* (e.g. "Claude
  Code", "Codex", "Open Code") — shown **only** when an agent is running.
- **Right of the agent name:** a colored *agent-state pill* with a text word
  (Waiting / Working / Blocked) — shown **only** when an agent is running.
- **Tab icon** (iOS tab strip, Android tab strip, macOS top bar): uses the
  agent-state color scheme + flashing to convey the state at a glance.

## Terminology decision: "Waiting"

The user's four agent states are **Waiting / Working / Blocked / Unknown**.
The existing `AgentDetectedState` enum has `idle / working / blocked / unknown`,
where `idle` means "agent running, awaiting user input".

**Decision:** "Waiting" is a **display relabel of the existing `idle` state**.
No enum, server, or wire change. The UI shows the word "Waiting" wherever the
state is `.idle`. `unknown` remains the fourth state (rare; gray, and since a
pill is only shown when an agent is running, it will seldom surface).

## Data model (unchanged, for reference)

- `SessionState` (`ClaudeRelayKit`): `created, starting, activeAttached,
  activeDetached, resuming, exited, failed, terminated, expired`.
- `AgentDetectedState`: `idle, working, blocked, unknown`.
- `SessionInfo.agent: String?` — agent id ("claude", "codex", "opencode") or nil
  when no agent is running.
- `SessionInfo.agentState: AgentDetectedState?` — nil when no agent / legacy server.
- `CodingAgent.displayName` — registry display name ("Claude Code", "Codex",
  "opencode").

## Visual specification

### Left dot — lifecycle/attachment (replaces the text pill)

Driven by `SessionState`:

| SessionState | Dot color |
|---|---|
| `activeAttached` | green |
| `activeDetached` | yellow |
| `starting`, `resuming` (transitional) | yellow |
| `created` | yellow |
| terminal (`exited`/`failed`/`terminated`/`expired`) | not shown in list |

The current lifecycle **text pill** (`session.state.rawValue`, e.g.
"active-attached") is **removed** and replaced by this dot on the left.

### Agent name (middle-right)

- Shown only when `SessionInfo.agent != nil`.
- Friendly names via a presentation mapping over `CodingAgent.displayName`:
  - `opencode` → **"Open Code"**
  - all others → registry `displayName` as-is ("Claude Code", "Codex").
- When no agent is running: no agent name, no agent-state pill.

### Agent-state pill (far right)

- Shown only when an agent is running (`agent != nil` and `agentState != nil`).
- Colored pill background + text word, reusing the existing ActivityDot color
  system:

| agentState | Pill word | Pill color |
|---|---|---|
| `.idle` | "Waiting" | teal (unseen) / green (seen) — matches ActivityDot idle |
| `.working` | "Working" | agent's palette color (`AgentColorPalette.color(for: agentId)`) |
| `.blocked` | "Blocked" | red |
| `.unknown` | "Unknown" | gray |

- The pill is **static in the session row** (does not flash). Flashing is
  reserved for the tab icon / macOS top bar.

### Tab icon (iOS tab strip + Android tab strip)

Extend the existing tab background to be driven by `agentState`:

| Condition | Background | Flash |
|---|---|---|
| `agentState == .blocked` | red | **yes** (pulse) |
| `agentState == .working` | agent palette color | no |
| `agentState == .idle` (Waiting) | teal/green | no |
| `agentState == .unknown` or no agent | neutral dim (current default) | no |

The tab keeps its number/label; only the background color and flash change.
This preserves the existing `flashOn` TimelineView plumbing.

### macOS top bar (`StatusBarView`) — macOS "tab icon" equivalent

macOS has no tab strip, so the top bar is its at-a-glance affordance. For the
**active session** the top bar shows, in addition to the existing connection dot:

```
[connection dot] "Excellent" ........ [● attach dot]  Claude Code  [🟥 Blocked]
```

- **Attach dot**: green/yellow via the same `SessionState` mapping as the sidebar
  left dot.
- **Agent name**: friendly name, only when an agent is running.
- **Agent-state pill**: same colored pill + word as the row. Because this is the
  macOS tab-icon equivalent, the pill/attach dot **may flash on `.blocked`**
  (matching iOS/Android tab flash), unlike the static sidebar-row pill.

macOS therefore changes in **two** places: the sidebar rows (row layout) and the
top bar (this).

## Architecture

Logic must be identical across clients but cannot be code-shared between Swift
and Kotlin. Centralize per language:

**Swift (`ClaudeRelayClient`, shared by iOS + macOS):**
- Extend `ActivityDot` (already shared) as needed for the tab/dot coloring.
- Add `AgentDisplayName.friendly(agentId:) -> String?` — presentation mapping
  over the registry (`opencode` → "Open Code").
- Add `AgentStatePill` view — colored pill + word from `agentState` (+ agentId +
  seen for the idle color). Reused by iOS row, macOS row, macOS top bar.
- Add a `SessionState` → dot-color helper (e.g. `SessionStatusDotColor` or an
  extension) so the left dot / attach dot render identically everywhere.

**Kotlin (`feature-workspace/ui`, Android):**
- Mirror the three: `friendlyAgentName(agentId)`, an `AgentStatePill`
  composable, and a `SessionState`→dot-color mapping.
- Keep hex color values in lockstep with the Swift `AgentColorPalette` /
  ActivityDot so platforms match.

**Single source of truth for friendly names:** presentation-only layer over
`CodingAgent.displayName`; the registry stays the data source.

## Affected files

**Swift shared (`Sources/ClaudeRelayClient`):**
- `Views/ActivityDot.swift` — color logic (already there; extend if needed).
- New: `Views/AgentStatePill.swift`, friendly-name helper, `SessionState` dot-color helper.

**iOS (`ClaudeRelayApp`):**
- `Views/SessionSidebarView.swift` — row layout: left dot, agent name, state pill; remove text pill.
- `Views/ActiveTerminalView.swift` — `SessionTab.tabBackground` driven by `agentState`.

**macOS (`ClaudeRelayMac`):**
- `Views/SessionSidebarView.swift` — row layout (same as iOS).
- `Views/StatusBarView.swift` — add attach dot + agent name + state pill for active session.

**Android (`ClaudeRelayAndroid/feature-workspace`):**
- `ui/SessionSidebar.kt` — row layout.
- `ui/SessionTabs.kt` — tab background driven by agentState.
- `ui/ActivityDot.kt` — color logic parity.
- New helpers: friendly name, `AgentStatePill`, SessionState dot-color.

## Testing

- **Swift:** unit-test pure mappings — `SessionState`→dot color,
  `agentState`→(pill word, pill color), `friendly(agentId:)`. Extend existing
  iOS `tabBackground` tests for the new agentState-driven coloring/flash.
- **Android:** extend the m32 `tabBackground` tests; add JUnit tests for pill
  color/word and friendly-name mapping.
- **No server/wire changes**, so no server-side tests. "Waiting" is a display
  relabel only.

## Out of scope / non-goals

- No new `waiting` state in the data model or wire protocol.
- No changes to server-side agent detection.
- No accessibility text-label additions beyond the pill words themselves
  (could be a future enhancement — the pill word itself already improves on the
  dot-only design for color-blind users).

## Backward compatibility

- Servers that don't report `agentState`/`agent` (legacy): no agent name, no
  pill; the left dot still renders from `SessionState`. Matches current
  graceful-degradation behavior.
