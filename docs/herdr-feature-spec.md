# herdr → CodeRelay — Feature Spec (post-parity build-out)

**Date:** 2026-07-22
**Method:** Reviewed [herdr](https://github.com/ogulcancelik/herdr) (README + docs: session-state,
socket-api, integrations, plugins, notifications, remote, concepts, agent-automation) against a
full inventory of CodeRelay's current features, then ran a feature-by-feature inclusion vote.
This spec captures **only the features selected for the spec** — six of twelve candidates — with
scope grounded in the actual code that each one touches.

## Verdict

CodeRelay has already won the hard, subtle part: **herdr-grade agent-state detection**
(`AgentDetectedState`, which explicitly "Mirrors herdr's AgentState") with anti-flap arbitration
and a client-side "seen"/needs-attention model. The gap is **not** detection — it is (1) getting
that signal **out of the app** to the user, and (2) making a **fleet** of sessions triageable.

The selected work doubles down on CodeRelay's identity as the best *remote window / observer* onto
a herd of agents. It deliberately **excludes** herdr's "become-a-multiplexer/orchestrator" axis
(agent-facing socket API, inter-agent orchestration, plugin marketplace, tiled panes, mouse). See
§Excluded for the rejected candidates and the rationale, so the decision is on the record.

Notable framing point: herdr itself has **no native push** — its only phone-alert story is a
third-party community plugin (`AltanS/collie`, "push when an agent needs you"). The P0 work below
makes CodeRelay do natively what herdr can only do via a plugin.

---

## Selected features

| # | Feature | Priority | Coupling |
|---|---|---|---|
| F1 | Push notifications (blocked / idle-unseen) | **P0** | Pushes the F2 rollup, not per-session |
| F2 | Workspace status rollups | **P0** | Feeds F1 |
| F5 | Broader agent support | **P1** | — |
| F6 | Hook-based state authority | **P1** | Shares the hook mechanism formerly scoped for convo-resume |
| F3 | Session/layout persistence & restore | **P2** | — |
| F11 | Clipboard bridging + host auto-provision | **P2** | Builds on existing image-paste |

---

## F1 — Push notifications when an agent blocks or finishes · **P0**

### Problem
Attention today is **in-app only**. `SessionActivityMonitor` detects `blocked` server-side and
`ActivityCoordinator` raises a "needs attention" flag (red pulsing dot, flashing tab, macOS
menu-bar badge, the `unseenSessions` "seen" bit), but the app must be **open and foregrounded** to
see any of it. There is zero push infrastructure — no `UNUserNotificationCenter`,
`registerForRemoteNotifications`, APNs, or FCM anywhere in the tree.

### What we build
A phone (or Mac) buzzes within ~2 s of an agent transitioning to `blocked` (needs input/approval)
or to idle-unseen (finished, not yet looked at) — from the lock screen the user taps through to that
session. This is the single highest-value feature for CodeRelay's form factor: it turns "a terminal
you can open on your phone" into "the thing that tells you when your agents need you."

### Scope
- **Server**: on the existing `SessionActivityMonitor.onChange` state transition, emit a push when
  the new `AgentDetectedState` is `.blocked` (always) or transitions to idle-unseen (config-gated).
  Coalesce with the F2 rollup — push *"repo X needs you (2 agents blocked)"*, not one per session.
  Respect ownership (`tokenId`) — only push to devices that own / can see the session.
- **Device registration**: new wire messages (`register_push_token` / ack) carrying an APNs token
  (iOS/macOS) or FCM token (Android) + platform; stored against the token, TTL-reaped like other
  per-token state.
- **Delivery**: server-side APNs (HTTP/2, token-based auth via a `.p8` — same auth family already
  used for TestFlight) and FCM sender. Config keys for credentials/paths.
- **Client**: request notification permission (respect a settings toggle); handle tap → deep-link
  into the session (the `clauderelay://session/<uuid>` scheme already exists — reuse `handleDeepLink`).
- **Settings**: per-app toggle; choice of "blocked only" vs "blocked + finished".

### Touches
`SessionActivityMonitor.swift`, `ServerMessage.swift`/`ClientMessage.swift` (new push-token msgs),
`TokenStore.swift`, `RelayConfig.swift` (APNs/FCM config), new server push sender,
`ClaudeRelayApp.swift` + `ClaudeRelayMac` app delegates (registration + tap handling),
Android FCM service + `feature-*`, `AppSettings.swift` (toggle).

### Explicitly out of scope
No per-session custom triggers (that would be output-matching, which was **rejected** — see
Excluded F7). Push fires only on the states CodeRelay already classifies.

### Acceptance
Agent hits a permission prompt with the app backgrounded/killed → device receives a notification
within a few seconds → tap opens that session. Toggling the setting off suppresses delivery.
Ownership is honored (a device that doesn't own a session never receives its push).

---

## F2 — Workspace-level status rollups · **P0**

### Problem
The session list is **flat** (`SessionSidebarView`, `sessionTabBar`). With a real fleet there is no
grouping and no aggregate "this project needs attention" signal — you scan every row to triage.
herdr groups agents under workspaces (one per repo/task) and rolls the sidebar state up from the
agents inside, "so you can see which project needs attention."

### What we build
A grouping layer over sessions with a rolled-up **worst-state** badge per group. Default grouping by
working directory / repo (derivable from the PTY cwd); user-defined groups as a later refinement.

### Scope
- **Grouping key**: derive from the session's cwd/repo. Server already runs the PTY; surface the
  session's working directory (or git root) so the client can group.
- **Rollup rule**: group state = worst of its members using the existing needs-attention ordering
  (`blocked` > idle-unseen > `working` > idle-seen > `unknown`). Reuse `AgentDetectedState` and the
  `unseenSessions` "seen" bit — do **not** invent a parallel state model.
- **UI**: collapsible group headers in `SessionSidebarView` (iOS/mac/Android) with an aggregate
  `ActivityDot`/badge; count of members needing attention.
- **Feeds F1**: the push coalescer keys on the group so users get one actionable alert per project.

### Touches
`SessionManager` / `SessionInfo` (surface cwd/repo), `ActivityCoordinator.swift` (rollup
computation), `SessionSidebarView.swift` (iOS/mac) + Android `SessionSidebar.kt`, shared
`ActivityDot`/badge atoms.

### Acceptance
Sessions group by repo; a group with any `blocked` member shows a red rollup badge; collapsing a
group preserves the aggregate signal; the rollup drives a single coalesced F1 push.

---

## F5 — Broader agent support · **P1**

### Problem
CodeRelay ships detection for **3** agents (Claude Code, Codex, opencode); herdr covers **14**. The
architecture is already built for breadth — a new agent is a `CodingAgent.all` entry plus a
screen-region manifest JSON.

### What we build
Add first-class detection for the highest-value missing agents. Initial targets: **GitHub Copilot
CLI, Cursor Agent CLI, Droid** (revisit the rest of herdr's list as demand appears).

### Scope
- Per agent: a `CodingAgent` record (id, displayName, processNames, titleKeywords) + a
  `Resources/Agents/<id>.json` screen-region manifest (working/idle/blocked gate rules), plus a
  color in `AgentColorPalette` (guard contrast per the recent `Color+Contrast` work).
- Validate detection against real transcripts of each agent's working/idle/blocked screens.
- Android parity: mirror the manifest + palette entry.

### Touches
`CodingAgent.swift`, `Resources/Agents/*.json`, `AgentColorPalette.swift` (+ Android mirror),
`AgentStateDetector`/`AgentManifest` (no engine change — data only).

### Acceptance
Each new agent is detected (name + working/idle/blocked) with no regression to the existing three;
manifests live in-repo with user-override support (`~/.claude-relay/agents/<id>.json`) intact.

---

## F6 — Hook-based state authority · **P1**

### Problem
State detection is **pure screen-scraping** (`AgentStateDetector` + manifests, process poll, OSC
titles), defended against flicker by anti-flap heuristics (startup grace, pending-idle hold,
overlay-freeze). herdr gets **authoritative** state for supported agents from **hooks** that author
`idle`/`working`/`blocked` directly, skipping the screen fallback and a whole class of
misdetections.

### What we build
Adopt Claude Code's hook mechanism (herdr reports session identity to a local socket on session
start; the same channel can carry lifecycle state). When a hook is actively reporting for a session,
its semantic state is **authoritative** and the screen manifest becomes fallback only — matching
herdr's "lifecycle authority" integration tier.

### Scope
- A minimal local channel the hook writes to (localhost, per the existing Admin HTTP surface or a
  dedicated localhost endpoint — **not** a general agent-facing socket API; that was rejected, see
  Excluded F8). Keep it scoped to *state reporting for the local Claude Code hook*, nothing more.
- `SessionActivityMonitor` prefers hook-authored state when fresh; falls back to screen detection
  when the hook is stale/absent. Preserve the `revision` monotonic ordering already on
  `session_activity`.
- **Scope guard:** state only. The same hook could carry a resume-session id, but conversation
  resume (F4) was **rejected** — do not build resume plumbing now. The hook is designed so resume
  can be layered on later without rework.

### Touches
`SessionActivityMonitor.swift`, `AdminRoutes.swift` (or a scoped localhost state endpoint),
a Claude Code hook script shipped with the server, docs for installing it.

### Acceptance
With the hook installed, `blocked`/`working`/`idle` reflect Claude Code's real lifecycle without
the screen-detection anti-flap lag; with the hook absent, behavior is identical to today.

---

## F3 — Session/layout persistence & restore · **P2**

### Problem
Sessions never expire (`detachTimeout=0`) and scrollback replays on attach, but **layout is not
restored**: which sessions were open, tab order, the active session, and per-device focus are lost
on reconnect — reconnection is a cold re-fetch. herdr persists "workspaces, tabs, panes, cwd,
layout, and focus."

### What we build
Persist and restore the client's *workspace shape* per device: open session set, tab order, active
session, sidebar/group collapse state. Reconnection re-opens the same working set instead of a bare
list.

### Scope
- Client-side, per-device state (extend `SessionOwnershipStore`, which already mirrors
  ownership/agent state to `UserDefaults`) — no server schema change required for v1.
- On recovery (`RecoveryController` / `SharedSessionCoordinator.handleForegroundTransition`),
  re-open the persisted working set (bounded by the existing 8-session LRU terminal cache) and
  re-select the active session.
- Cross-device: focus/active is per-device (does not stomp another device's view).

### Touches
`SessionOwnershipStore.swift`, `SharedSessionCoordinator.swift`, `RecoveryController.swift`,
`TerminalCache.swift`, Android session coordinator mirror.

### Acceptance
Kill and relaunch the app (or drop and recover the connection) → the same sessions are open in the
same order with the same active tab, without a manual re-open.

---

## F11 — Clipboard bridging + host auto-provision · **P2**

### Problem
CodeRelay already does **one-way image paste** (`paste_image` base64 PNG → Mac pasteboard via
`MacClipboardService`) — a real parity point with herdr's clipboard bridge. Missing: **two-way**
text/clipboard sync and the "auto-install/provision on the host" convenience herdr's
`--remote <host>` thin client offers.

### What we build
Bidirectional clipboard sync (copy in the terminal → available on the device, and vice-versa,
text + image) and a smoother host-provisioning path.

### Scope
- **Clipboard**: extend the existing paste path to a two-way sync — terminal-side copy (OSC 52 or a
  server read of the Mac pasteboard) surfaced to the device clipboard, and device → host as today.
  Respect size caps (existing 10 MB frame / image limits).
- **Host auto-provision**: lower-priority convenience — streamline installing/starting the relay
  server on a target host (the CLI `load` flow already locates the binary via a fallback chain;
  extend toward a one-command remote setup). Keep this exploratory within P2.

### Touches
`ImagePasteHandler.swift`, `MacClipboardService.swift`, `RelayMessageHandler` (clipboard messages),
client clipboard integration (iOS/mac/Android), CLI `load`/provisioning path.

### Acceptance
Copying selected text in a session makes it pasteable on the phone (and back); image paste continues
to work; provisioning a fresh host requires materially fewer manual steps than today.

---

## Excluded candidates (on the record)

| # | Feature | Decision | Rationale |
|---|---|---|---|
| F4 | Agent conversation resume via native session refs | **No** | Deferred; F6's hook is designed so this can layer on later without rework |
| F7 | Output matching / regex triggers | **No** | Push fires only on states CodeRelay already classifies; no custom trigger engine |
| F8 | Agent-facing socket API + inter-agent orchestration | **No** | Large new subsystem; furthest from the remote-window/observer identity |
| F9 | Plugin system + marketplace | **No** | Depends on F8; large surface area |
| F10 | Split/tiled panes | **No** | Tab-switching is correct for mobile; tiling is a big view-layer change |
| F12 | Mouse support (SGR reporting) | **No** | Low value on touch; niche on desktop |

**Theme of the exclusions:** CodeRelay is **not** trying to become herdr (a terminal multiplexer /
agent orchestrator). It remains the best *remote window* onto a herd, and invests in out-of-app
alerting (F1/F2), detection breadth & accuracy (F5/F6), and reconnect/desktop ergonomics (F3/F11).

---

## Suggested sequencing

1. **F2 then F1** — build the rollup first so push can key on it (one actionable alert per project,
   not per session).
2. **F6 then F5** — land the hook channel and authority model, then widen agent coverage (F5
   manifests benefit from the more reliable state signal).
3. **F3, F11** — ergonomics polish once the P0/P1 core is in.
