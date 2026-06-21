# Session Tab Strip Auto-Scroll — Design

**Date:** 2026-06-21
**Status:** Approved (pending implementation plan)
**Platforms:** iOS (`ClaudeRelayApp`), Android (`ClaudeRelayAndroid`)

## Problem

In the terminal workspace, a horizontal strip of numbered mini-tabs ("1", "2",
"3", …) represents the active sessions. The selected session's tab gets a 2 pt
white selection border. But when there are more sessions than fit on screen, the
strip **never scrolls** in response to a selection change — so selecting a
session whose tab is off-screen (e.g. from the left session menu) leaves the
selected tab invisible.

Current state:
- **iOS** — `ActiveTerminalView.swift` `sessionTabBar` is a plain
  `ScrollView(.horizontal)` with no `ScrollViewReader`; selection never moves
  the scroll offset.
- **Android** — `SessionTabs.kt` is a `LazyRow` with no hoisted
  `LazyListState`; nothing drives a programmatic scroll.

## Desired behavior

When the active session changes, the strip should **smoothly scroll the minimum
amount needed to bring the selected tab fully on-screen** ("minimal reveal"):

- If the selected tab is already fully visible → **do not move**.
- If it's off-screen or clipped → scroll just enough so it becomes fully visible
  at the **nearest edge** (not centered).
  - Example: sessions `1 2 3 4 5`, three visible at a time. `1 2 3` visible,
    user selects `4` from the left session menu → strip scrolls left until
    `2 3 4` are visible.
- Smooth animation (~250–300 ms ease).

### Triggers

All of these change the active session and must auto-scroll:
- Tapping a tab (including a partially-clipped one).
- Selecting a session from the sidebar / session list.
- Creating + auto-selecting a new session (tab usually at the far end).
- Recovery / reconnect restoring the active session programmatically.
- Device **rotation / window resize** (re-reveal, since the number of visible
  tabs changes).

### Core insight

All four selection triggers funnel through a single value —
`coordinator.activeSessionId` (`@Published UUID?` on iOS; a `StateFlow<UUID?>`
collected as state on Android). So both platforms only need to **observe that
one value** (plus a layout-change signal) and perform a minimal reveal. No
per-trigger wiring is required.

## Approach (chosen: native scroll-into-view, minimal reveal)

Use each platform's built-in scroll-into-view mechanism, keyed on
`activeSessionId`. Rejected alternatives: always-centering (user explicitly
wants minimal reveal, not centering); manual pixel-offset math on both
(reimplements native APIs, fragile vs. dynamic tab widths).

### iOS — `ActiveTerminalView.swift` (`sessionTabBar`)

- Wrap the existing `ScrollView(.horizontal)` in `ScrollViewReader { proxy in … }`.
- Tag each `SessionTab` with `.id(session.id)` inside the existing `ForEach`
  over `coordinator.activeSessions`.
- Add `.onChange(of: coordinator.activeSessionId)` that reveals the new id:

  ```swift
  withAnimation(.easeInOut(duration: 0.25)) {
      proxy.scrollTo(id, anchor: nil)   // nil anchor == minimal reveal; no-op if already visible
  }
  ```

  SwiftUI's `nil`-anchor `scrollTo` is *exactly* minimal-reveal: it scrolls the
  least amount to make the item visible and is a no-op when it already is. This
  is the entire algorithm, for free.
- **Rotation/resize:** re-run the same reveal on a layout-change signal
  (orientation-change notification, or `.onChange` of the bar's width via a
  `GeometryReader`), re-calling `scrollTo` for the current `activeSessionId`.
- **Initial appearance:** `.onAppear` reveal (no animation on first paint) so a
  restored / deep-linked session starts visible.

`SessionTab` itself is untouched. The change is local to the `sessionTabBar`
`@ViewBuilder`.

### Android — `SessionTabs.kt` + caller (`WorkspaceScreen.kt`)

- Hoist `val listState = rememberLazyListState()` and pass `state = listState`
  to the `LazyRow`.
- Extract the reveal decision into a **pure, internal, unit-testable** helper
  (matching the existing `SessionTabsLogicTest.kt` pattern that tests
  `tabBackground` without Compose UI):

  ```kotlin
  // Returns the target index to scroll to (and which edge), or null if the
  // selected tab is already fully visible. Inspects visibleItemsInfo:
  //  - fully visible            -> null
  //  - off the left  (clipped)  -> make it the leading visible item
  //  - off the right (clipped)  -> make it the trailing visible item (minimal)
  fun revealTarget(layoutInfo: LazyListLayoutInfo, selectedIndex: Int): RevealTarget?
  ```

- Add `LaunchedEffect(activeSessionId, listState.layoutInfo.viewportSize)`
  (viewportSize change covers rotation/resize). It resolves the selected index,
  calls `revealTarget`, and if non-null calls `listState.animateScrollToItem(...)`
  with the computed index/offset. Default `animateScrollToItem` snaps the item
  to the leading edge, so the helper computes the offset needed for the
  trailing-edge (off-right) case to keep the reveal minimal.

## Component boundaries

- **iOS:** isolated to the `sessionTabBar` `@ViewBuilder` in
  `ActiveTerminalView.swift`. No new types.
- **Android:** `SessionTabs` gains a hoisted `LazyListState` + a
  `LaunchedEffect`; the reveal math lives in `revealTarget(...)` so it's tested
  without rendering Compose.

## Testing

- **Android (unit):** `revealTarget` — already-visible → null; off-left →
  leading index; off-right → trailing computation; single item; selection at
  both ends; empty list.
- **iOS:** the `nil`-anchor `scrollTo` *is* the algorithm (SwiftUI-internal, not
  unit-testable directly); covered by the behavior contract + manual
  verification on device.

## Out of scope (YAGNI)

- Centering the selected tab.
- Drag-to-reorder tabs.
- Persisting scroll position across launches.
- Scroll indicators / edge-fade affordances.
