# Bright-Orange Flashing Tab for Waiting Sessions

**Date:** 2026-07-26
**Platforms:** iOS + Android (identical shared tab structure)
**Status:** Approved for implementation

## Goal

When a session is *waiting for the user* (the agent finished its turn and is
awaiting a response), make its numbered tab in the top tab strip **flash bright
orange** so the user can spot it at a glance across many tabs.

## Which "waiting" state

The state model has two distinct "waiting" notions in `AgentDetectedState`:

- **`.idle`** — agent finished, waiting for the user. Labeled **"Waiting"** in
  the app. Today: a **static yellow** tab, no attention pulse. **This is the
  state we are changing.**
- **`.blocked`** — agent hit a permission prompt / mid-task question. Labeled
  "Blocked". Today: already flashes **red**. **Unchanged.**

Decision: only `.idle` flashes orange. `.blocked` keeps its red flash.

## The orange-clash problem

Claude's agent color is already orange (`#FFA500`), so a *working* Claude tab is
solid orange. To keep *waiting* visually distinct from *working*:

- **Waiting** flashes **bright orange ↔ near-black** (`#FF9500` ↔ `#1A1A1A`).
- **Working** stays **solid** agent color.

Motion is the differentiator: a *pulsing* tab = waiting, a *steady* tab =
working. The waiting orange (`#FF9500`, iOS systemOrange) is also a hotter,
purer orange than Claude's amber `#FFA500` working color.

## Scope

**Top tab strip only.** The sidebar dots (`ActivityDot`), pills
(`AgentStatePill`), and status dots keep their current behavior. This matches
the request ("the tab icon on the top").

No changes to the state model, wire protocol, `ActivityCoordinator`,
`SessionActivityMonitor`, or any coordinator plumbing. This is a pure
view-layer color/animation change in the two tab-background functions plus the
iOS flash-clock gate.

## Implementation

### Android (`SessionTabs.kt`)

The `InfiniteTransition` flash clock **always runs**, so `flashOn` is always
live. Only the color branch changes.

1. Add a waiting-orange constant near `White15`:
   ```kotlin
   private val WaitingOrange = Color(0xFFFF9500)
   private val WaitingFlashDark = Color(0xFF1A1A1A)
   ```
2. In `tabBackground(...)`, change the `IDLE` branch from static yellow to a
   flash:
   ```kotlin
   AgentDetectedState.IDLE -> if (flashOn) WaitingOrange else WaitingFlashDark
   ```
3. Widen `needsAttention` in `SessionTabs` so it is also true for `IDLE`. This
   keeps the "which tabs are pulsing" concept honest and matches iOS. (The
   fill for IDLE is driven directly by the `agentState` branch, but keeping
   `needsAttention` consistent avoids surprises for any future reader.)
   ```kotlin
   val needsAttention = if (agentState != null) {
       agentState == AgentDetectedState.BLOCKED || agentState == AgentDetectedState.IDLE
   } else {
       awaitingInput.contains(session.id)
   }
   ```

The label-contrast helper (`tabLabelColor`) already handles both bright orange
(→ white label, luma < 0.6) and near-black (→ white label), so the number stays
legible through the flash.

### iOS (`ActiveTerminalView.swift`)

The iOS flash clock is a `TimelineView` **gated on
`coordinator.sessionsAwaitingInput.isEmpty`** (line 144). Critically,
`sessionsAwaitingInput` is derived from the **legacy coarse**
`ActivityState.agentIdle`, *not* from the fine-grained `AgentDetectedState.idle`.
So changing the `.idle` color branch alone would NOT animate — the clock must
also run when any session reports fine-grained `.idle`.

1. Add a helper on the view that is true when any active session should be
   flashing (blocked OR idle, via fine-grained state), falling back to the
   legacy `sessionsAwaitingInput` set:
   ```swift
   private var anyTabNeedsFlash: Bool {
       coordinator.activeSessions.contains { session in
           if let s = coordinator.agentState(for: session.id) {
               return s == .blocked || s == .idle
           }
           return coordinator.sessionsAwaitingInput.contains(session.id)
       }
   }
   ```
2. Replace the gate at line 144:
   ```swift
   if anyTabNeedsFlash {
       TimelineView(.periodic(from: .now, by: 0.5)) { context in
           let flashOn = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
           sessionTabBar(flashOn: flashOn)
       }
   } else {
       sessionTabBar(flashOn: false)
   }
   ```
3. Widen `needsAttention` in `sessionTabBar` to include `.idle`:
   ```swift
   let needsAttention = agentState != nil
       ? (agentState == .blocked || agentState == .idle)
       : coordinator.sessionsAwaitingInput.contains(session.id)
   ```
4. In `SessionTab.tabBackground`, change the `.idle` branch:
   ```swift
   case .idle: return flashOn ? Color(red: 1.0, green: 0.584, blue: 0.0)  // #FF9500
                              : Color(red: 0.10, green: 0.10, blue: 0.10) // #1A1A1A
   ```
   (Extract as a named `static let waitingOrange` / `waitingFlashDark` on the
   struct for clarity.)

The existing `.animation(.easeInOut(duration: 0.15), value: flashOn)` gives the
same smooth 2 Hz pulse the blocked tab already uses.

## Consistency between platforms

Both apps flash at ~2 Hz (iOS `TimelineView` 0.5 s half-period; Android
`infiniteRepeatable` 500 ms reverse). Same orange, same dark, same states. No
divergence introduced.

## Trade-offs accepted

- **iOS redraw when idle:** widening the flash gate means the top-bar
  `TimelineView` now runs whenever any session is merely *waiting* (not just
  *blocked*). Cost is one shared 2 Hz timeline across all tabs — the same
  mechanism blocked already uses; negligible.
- **Working vs waiting for Claude both read as orange** in a still frame; the
  flash (motion) is the sole differentiator. Accepted per design discussion —
  the bright/dark pulse is unmistakable against a steady fill.

## Testing / verification

`tabBackground` on Android is already a pure, `internal` function → add a unit
test asserting `IDLE` returns `WaitingOrange` when `flashOn` and
`WaitingFlashDark` otherwise (parity with the existing `White15`/`QualityRed`
expectations if such tests exist). iOS `tabBackground` is private view code;
verify by building the app and visual inspection. Build both apps; confirm:
- A finished ("Waiting") Claude session pulses orange↔dark.
- A working Claude session stays solid orange (no pulse).
- A blocked session still pulses red.
- The tab number stays legible across the whole flash.
