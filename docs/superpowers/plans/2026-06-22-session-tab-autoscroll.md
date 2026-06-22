# Session Tab Strip Auto-Scroll Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the active session changes (or the device rotates/resizes), smoothly scroll the numbered session-tab strip the minimum amount needed to bring the selected tab fully on-screen, on both iOS and Android.

**Architecture:** Both platforms observe the single source of truth `coordinator.activeSessionId` (every selection path — tap, sidebar, new session, recovery — funnels through it). iOS wraps the existing horizontal `ScrollView` in a `ScrollViewReader` and calls `scrollTo(id, anchor: nil)` (native minimal-reveal). Android hoists a `LazyListState` into the existing `LazyRow` and drives `animateScrollToItem` from a pure, unit-tested `revealTarget(...)` helper that computes minimal-reveal from `LazyListLayoutInfo`.

**Tech Stack:** SwiftUI (`ScrollViewReader`, `.onChange`), Jetpack Compose (`LazyListState`, `LaunchedEffect`), JUnit 5 (Jupiter) for Android unit tests.

## Global Constraints

- **Minimal reveal, not centering:** already-fully-visible selected tab → no scroll; off-screen/clipped → scroll the minimum to make it fully visible at the nearest edge.
- **Triggers (all flow through `activeSessionId`):** tab tap (incl. partially-clipped), sidebar/list selection, new-session creation, recovery/reconnect, plus device rotation / window resize.
- **Animation:** smooth, ~250–300 ms ease.
- **No-op guards:** empty session list or `activeSessionId == nil` → do nothing; never crash.
- **SwiftLint:** line length warning at 140, error at 200; identifier min length 2.
- **iOS file:** `ClaudeRelayApp/Views/ActiveTerminalView.swift` — the strip is the `sessionTabBar(flashOn:)` `@ViewBuilder` (currently lines ~232-257), invoked at two call sites (lines ~118 and ~122). All changes live inside the builder so both sites are covered by one edit.
- **Android files:** `ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/SessionTabs.kt` and its test `.../src/test/kotlin/relay/feature/workspace/ui/SessionTabsLogicTest.kt`.
- **Android test command:** `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:testDebugUnitTest --tests "*SessionTabsLogicTest*"`.

---

### Task 1: Android — `revealTarget` minimal-reveal helper (pure, tested)

**Files:**
- Modify: `ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/SessionTabs.kt`
- Test: `ClaudeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/ui/SessionTabsLogicTest.kt`

**Interfaces:**
- Consumes: nothing (pure function over plain inputs).
- Produces:
  - `data class VisibleTab(val index: Int, val offset: Int, val size: Int)` — a minimal stand-in for `LazyListItemInfo` so the logic is testable without Compose. `offset` is the item's left edge relative to the viewport's left edge (can be negative if clipped left); `size` is the item width in px.
  - `enum class RevealEdge { LEADING, TRAILING }`
  - `data class RevealTarget(val index: Int, val edge: RevealEdge)`
  - `fun revealTarget(visible: List<VisibleTab>, viewportWidth: Int, selectedIndex: Int): RevealTarget?`
    - Returns `null` when the selected item is present in `visible` AND fully inside `[0, viewportWidth]`.
    - Returns `RevealTarget(selectedIndex, LEADING)` when the selected item is off/clipped at the left, OR not present and `selectedIndex` is below the first visible index.
    - Returns `RevealTarget(selectedIndex, TRAILING)` when off/clipped at the right, OR not present and `selectedIndex` is above the last visible index.

- [ ] **Step 1: Write the failing test**

Append to `SessionTabsLogicTest.kt` (inside the existing class, after the existing tests):

```kotlin
    // --- revealTarget: minimal-reveal scroll decision ---

    // Viewport 300px wide, three 100px tabs visible at offsets 0,100,200.
    private fun threeVisible() = listOf(
        VisibleTab(index = 0, offset = 0, size = 100),
        VisibleTab(index = 1, offset = 100, size = 100),
        VisibleTab(index = 2, offset = 200, size = 100),
    )

    @Test
    fun `fully visible selection does not scroll`() {
        assertEquals(null, revealTarget(threeVisible(), viewportWidth = 300, selectedIndex = 1))
    }

    @Test
    fun `selection clipped at right reveals trailing`() {
        // index 2 spans 200..300 exactly; index 3 would be off-screen (not in visible list)
        assertEquals(
            RevealTarget(3, RevealEdge.TRAILING),
            revealTarget(threeVisible(), viewportWidth = 300, selectedIndex = 3),
        )
    }

    @Test
    fun `selection before first visible reveals leading`() {
        // first visible index is 2; selecting 0 should bring it to the leading edge
        val shifted = listOf(
            VisibleTab(index = 2, offset = 0, size = 100),
            VisibleTab(index = 3, offset = 100, size = 100),
            VisibleTab(index = 4, offset = 200, size = 100),
        )
        assertEquals(
            RevealTarget(0, RevealEdge.LEADING),
            revealTarget(shifted, viewportWidth = 300, selectedIndex = 0),
        )
    }

    @Test
    fun `partially clipped left edge reveals leading`() {
        // index 0 starts at -20 (clipped left), so it is not fully visible
        val clipped = listOf(
            VisibleTab(index = 0, offset = -20, size = 100),
            VisibleTab(index = 1, offset = 80, size = 100),
            VisibleTab(index = 2, offset = 180, size = 100),
        )
        assertEquals(
            RevealTarget(0, RevealEdge.LEADING),
            revealTarget(clipped, viewportWidth = 300, selectedIndex = 0),
        )
    }

    @Test
    fun `partially clipped right edge reveals trailing`() {
        // index 2 spans 180..280 fully visible; index 3 spans 280..380 clipped right
        val clipped = listOf(
            VisibleTab(index = 1, offset = 80, size = 100),
            VisibleTab(index = 2, offset = 180, size = 100),
            VisibleTab(index = 3, offset = 280, size = 100),
        )
        assertEquals(
            RevealTarget(3, RevealEdge.TRAILING),
            revealTarget(clipped, viewportWidth = 300, selectedIndex = 3),
        )
    }

    @Test
    fun `empty visible list does not scroll`() {
        assertEquals(null, revealTarget(emptyList(), viewportWidth = 300, selectedIndex = 0))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:testDebugUnitTest --tests "*SessionTabsLogicTest*"`
Expected: FAIL — compilation error, `revealTarget` / `VisibleTab` / `RevealTarget` / `RevealEdge` unresolved.

- [ ] **Step 3: Write minimal implementation**

Add to `SessionTabs.kt` (top-level, after the `White15` declaration near line 98):

```kotlin
/** Which edge a minimal-reveal scroll should align the selected tab to. */
internal enum class RevealEdge { LEADING, TRAILING }

/** A visible tab's geometry relative to the viewport's left edge (px). */
internal data class VisibleTab(val index: Int, val offset: Int, val size: Int)

/** Result of a minimal-reveal decision: scroll [index] to [edge], or no-op if null. */
internal data class RevealTarget(val index: Int, val edge: RevealEdge)

/**
 * Minimal-reveal decision for the session tab strip. Returns the target tab and
 * edge to scroll to, or null when the selected tab is already fully visible.
 *
 *  - selected fully inside [0, viewportWidth]      -> null (no scroll)
 *  - selected clipped/absent on the left           -> LEADING
 *  - selected clipped/absent on the right          -> TRAILING
 */
internal fun revealTarget(
    visible: List<VisibleTab>,
    viewportWidth: Int,
    selectedIndex: Int,
): RevealTarget? {
    if (visible.isEmpty()) return null
    val selected = visible.firstOrNull { it.index == selectedIndex }
    if (selected != null) {
        val fullyVisible = selected.offset >= 0 && selected.offset + selected.size <= viewportWidth
        if (fullyVisible) return null
        val edge = if (selected.offset < 0) RevealEdge.LEADING else RevealEdge.TRAILING
        return RevealTarget(selectedIndex, edge)
    }
    // Not currently laid out: decide by position relative to the visible window.
    val firstIndex = visible.first().index
    val edge = if (selectedIndex < firstIndex) RevealEdge.LEADING else RevealEdge.TRAILING
    return RevealTarget(selectedIndex, edge)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:testDebugUnitTest --tests "*SessionTabsLogicTest*"`
Expected: PASS (all existing `tabBackground` tests + 6 new `revealTarget` tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/SessionTabs.kt ClaudeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/ui/SessionTabsLogicTest.kt
git commit -m "feat(android): add revealTarget minimal-reveal helper for session tabs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Android — wire `LazyListState` + `LaunchedEffect` into `SessionTabs`

**Files:**
- Modify: `ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/SessionTabs.kt`

**Interfaces:**
- Consumes: `revealTarget`, `VisibleTab`, `RevealEdge`, `RevealTarget` from Task 1.
- Produces: no new public API; `SessionTabs(...)` signature is unchanged (the scroll state is internal to the composable).

- [ ] **Step 1: Add imports**

At the top of `SessionTabs.kt`, add these imports alongside the existing ones:

```kotlin
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
```

- [ ] **Step 2: Hoist the list state and drive the reveal**

In the `SessionTabs` composable, replace the `LazyRow(...) { itemsIndexed(...) }` block (currently lines ~75-94) with the version below. The two changes: a `rememberLazyListState()` passed as `state`, and a `LaunchedEffect` that maps `activeSessionId` to the selected index and performs the minimal-reveal scroll.

```kotlin
    val listState = rememberLazyListState()

    // Map the selected session id to its index in the current ordering.
    val selectedIndex = remember(sessions, activeSessionId) {
        activeSessionId?.let { id -> sessions.indexOfFirst { it.id == id } } ?: -1
    }

    // Reveal the selected tab whenever the selection changes or the viewport
    // resizes (rotation / window resize changes viewportSize). Minimal-reveal:
    // no movement if already fully visible.
    LaunchedEffect(selectedIndex, listState.layoutInfo.viewportSize) {
        if (selectedIndex < 0) return@LaunchedEffect
        val info = listState.layoutInfo
        val viewportWidth = info.viewportSize.width
        if (viewportWidth <= 0) return@LaunchedEffect
        val visible = info.visibleItemsInfo.map {
            VisibleTab(index = it.index, offset = it.offset, size = it.size)
        }
        val target = revealTarget(visible, viewportWidth, selectedIndex) ?: return@LaunchedEffect
        when (target.edge) {
            RevealEdge.LEADING -> listState.animateScrollToItem(target.index)
            RevealEdge.TRAILING -> {
                // Align the item's trailing edge to the viewport's trailing edge:
                // scroll so the item sits at offset (viewportWidth - itemSize).
                val itemSize = visible.firstOrNull { it.index == target.index }?.size
                if (itemSize != null && itemSize < viewportWidth) {
                    listState.animateScrollToItem(target.index, -(viewportWidth - itemSize))
                } else {
                    listState.animateScrollToItem(target.index)
                }
            }
        }
    }

    LazyRow(
        state = listState,
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
        contentPadding = PaddingValues(horizontal = 2.dp),
    ) {
        itemsIndexed(sessions, key = { _, s -> s.id }) { index, session ->
            val isSelected = session.id == activeSessionId
            val agentId = agentForSession(session.id)
            val needsAttention = awaitingInput.contains(session.id)
            SessionTab(
                number = index + 1,
                isSelected = isSelected,
                agentId = agentId,
                needsAttention = needsAttention,
                flashOn = flashOn,
                onClick = { onSelect(session.id) },
            )
        }
    }
```

- [ ] **Step 3: Build the module to verify it compiles**

Run: `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Re-run unit tests (no regressions)**

Run: `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:testDebugUnitTest --tests "*SessionTabsLogicTest*"`
Expected: PASS.

- [ ] **Step 5: Manual verification**

Build & run the Android app. Create 5+ sessions so the strip overflows. From the session sidebar, select a session whose tab is off the right edge → strip animates left until that tab is fully visible at the right edge. Select one off the left → animates right to the leading edge. Select an already-visible tab → no movement. Rotate the device with an edge tab selected → strip re-reveals it.

- [ ] **Step 6: Commit**

```bash
git add ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/SessionTabs.kt
git commit -m "feat(android): auto-scroll session tab strip to reveal selected tab

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: iOS — auto-scroll `sessionTabBar` to reveal the selected tab

**Files:**
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift` — the `sessionTabBar(flashOn:)` builder (currently ~232-257).

**Interfaces:**
- Consumes: `coordinator.activeSessionId: UUID?`, `coordinator.activeSessions: [SessionInfo]` (already in scope in this view).
- Produces: no new API; behavior-only change inside the builder.

- [ ] **Step 1: Wrap the ScrollView in a ScrollViewReader and tag tabs**

Replace the body of `sessionTabBar(flashOn:)` (the `ScrollView(.horizontal) { HStack { ForEach … } }`) with the version below. Changes: a `ScrollViewReader` wrapper, `.id(session.id)` on each tab button, an `onChange` that reveals the active id with animation, and an `onAppear` that reveals without animation on first paint.

```swift
    @ViewBuilder
    private func sessionTabBar(flashOn: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(coordinator.activeSessions.enumerated()), id: \.element.id) { index, session in
                        let isSelected = session.id == coordinator.activeSessionId
                        let agentId = coordinator.activeAgent(for: session.id)
                        let needsAttention = coordinator.sessionsAwaitingInput.contains(session.id)
                        Button {
                            if settings.hapticFeedbackEnabled {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            Task { await coordinator.switchToSession(id: session.id) }
                        } label: {
                            SessionTab(
                                number: index + 1,
                                isSelected: isSelected,
                                agentId: agentId,
                                needsAttention: needsAttention,
                                flashOn: flashOn
                            )
                        }
                        .buttonStyle(.plain)
                        .id(session.id)
                    }
                }
            }
            .onChange(of: coordinator.activeSessionId) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newID, anchor: nil)
                }
            }
            .onAppear {
                if let id = coordinator.activeSessionId {
                    proxy.scrollTo(id, anchor: nil)
                }
            }
        }
    }
```

Note on `anchor: nil`: SwiftUI performs a minimal reveal — it scrolls just enough to make the item visible and is a no-op when already fully visible. This is the entire minimal-reveal behavior. (Contingency: if testing shows jitter when the tab is already visible on a given OS version, gate the `scrollTo` behind a visibility check; not expected, do not add pre-emptively.)

- [ ] **Step 2: Build the iOS app**

Run: `cd /Users/miguelriotinto/Developer/ClaudeRelay && xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Lint the changed file**

Run: `cd /Users/miguelriotinto/Developer/ClaudeRelay && swiftlint lint --quiet ClaudeRelayApp/Views/ActiveTerminalView.swift`
Expected: no errors (warnings at >140 cols acceptable; keep new lines under 140).

- [ ] **Step 4: Manual verification**

Run the iOS app in Simulator/device. Create 5+ sessions so the strip overflows. Selecting a session from the sidebar whose tab is off-screen → strip smoothly scrolls until that tab is fully visible (minimal: ends at the nearest edge, per the `1 2 3` → select `4` → `2 3 4` example). Already-visible selection → no movement. Tapping a partially-clipped tab → scrolls it fully in. Rotate device with an edge tab selected → re-reveals.

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayApp/Views/ActiveTerminalView.swift
git commit -m "feat(ios): auto-scroll session tab strip to reveal selected tab

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Notes on rotation/resize coverage

- **Android:** `listState.layoutInfo.viewportSize` is a `LaunchedEffect` key, so a rotation/resize that changes the viewport re-runs the reveal for the current selection. No extra code.
- **iOS:** `sessionTabBar` is rebuilt on rotation (the toolbar re-lays-out), and `.onChange(of: activeSessionId)` plus `.onAppear` cover selection and first paint. If a rotation with an unchanged selection ever fails to re-reveal in testing, add `.onChange(of: horizontalSizeClass)` (or a `GeometryReader` width `onChange`) calling the same `proxy.scrollTo`. Not added pre-emptively (YAGNI).
