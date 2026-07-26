# Waiting-Tab Orange Flash Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a session's top-strip tab flash bright orange when the agent is finished and waiting for the user (`AgentDetectedState.idle`).

**Architecture:** Pure view-layer change in the two tab-background functions plus the iOS flash-clock gate. No state-model, protocol, or coordinator changes. Android's flash clock always runs (only the color branch changes); iOS gates its flash `TimelineView` on the legacy `sessionsAwaitingInput` set, so that gate must widen to include fine-grained `.idle`.

**Tech Stack:** Swift/SwiftUI (iOS app, XcodeGen), Kotlin/Jetpack Compose (Android app, Gradle), JUnit 5 (Android unit tests).

## Global Constraints

- Waiting color: bright orange `#FF9500` flashing to near-black `#1A1A1A` at ~2 Hz.
- Only `AgentDetectedState.idle` changes. `.blocked` keeps its red flash; `.working` stays solid agent color; `.unknown` stays gray.
- Scope: top tab strip only. Sidebar dots (`ActivityDot`), pills (`AgentStatePill`), status dots — unchanged.
- Both platforms must stay visually identical (same colors, same states, same ~2 Hz cadence).
- SwiftLint: line-length warning 140 / error 200.

---

### Task 1: Android — flash the idle tab orange

**Files:**
- Modify: `ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/SessionTabs.kt`
- Test: `ClaudeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/ui/SessionTabsLogicTest.kt`

**Interfaces:**
- Consumes: existing `tabBackground(agentId: String?, needsAttention: Boolean, flashOn: Boolean, agentState: AgentDetectedState? = null): Color`, and the color constant `White15` (private in `SessionTabs.kt`).
- Produces: two new private color constants `WaitingOrange` (`Color(0xFFFF9500)`) and `WaitingFlashDark` (`Color(0xFF1A1A1A)`); `tabBackground` now returns a flashing orange for `AgentDetectedState.IDLE`.

- [ ] **Step 1: Update the existing idle test to expect the orange flash**

In `SessionTabsLogicTest.kt`, replace the `idle agentState is done teal` test (lines 58-64) with:

```kotlin
@Test
fun `idle agentState flashes between waiting orange and dark`() {
    assertEquals(
        WaitingOrange,
        tabBackground("claude", needsAttention = true, flashOn = true, agentState = AgentDetectedState.IDLE),
    )
    assertEquals(
        WaitingFlashDark,
        tabBackground("claude", needsAttention = true, flashOn = false, agentState = AgentDetectedState.IDLE),
    )
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:testDebugUnitTest --tests "relay.feature.workspace.ui.SessionTabsLogicTest"`
Expected: FAIL — `WaitingOrange` / `WaitingFlashDark` unresolved reference, and the `IDLE` branch still returns `IdleYellow`.

- [ ] **Step 3: Add the color constants**

In `SessionTabs.kt`, next to the `White15` constant (line 148), add:

```kotlin
/** Bright orange for a session waiting on the user (idle). Flashes to keep it
 * distinct from Claude's steady amber "working" fill — motion is the tell. */
private val WaitingOrange = Color(0xFFFF9500)

/** The dark half of the waiting flash. */
private val WaitingFlashDark = Color(0xFF1A1A1A)
```

- [ ] **Step 4: Flash the IDLE branch**

In `tabBackground` (line 206), change:

```kotlin
    AgentDetectedState.IDLE -> IdleYellow
```

to:

```kotlin
    AgentDetectedState.IDLE -> if (flashOn) WaitingOrange else WaitingFlashDark
```

- [ ] **Step 5: Widen `needsAttention` to include idle**

In `SessionTabs` (lines 129-133), change:

```kotlin
            val needsAttention = if (agentState != null) {
                agentState == AgentDetectedState.BLOCKED
            } else {
                awaitingInput.contains(session.id)
            }
```

to:

```kotlin
            val needsAttention = if (agentState != null) {
                agentState == AgentDetectedState.BLOCKED || agentState == AgentDetectedState.IDLE
            } else {
                awaitingInput.contains(session.id)
            }
```

- [ ] **Step 6: Update the label-contrast test for the new fills**

The `label is black on light fills` test (line 152-157) references `IdleYellow`, which the tab no longer shows. Replace that assertion line so the test still covers a light fill and adds the waiting-orange case:

```kotlin
    @Test
    fun `label is black on light fills`() {
        assertEquals(Color.Black, tabLabelColor(WaitingOrange))              // orange ~0.64
        assertEquals(Color.Black, tabLabelColor(agentColor("claude")))       // orange ~0.68
        assertEquals(Color.Black, tabLabelColor(UnknownGray))                // gray ~0.62
    }
```

Then in `label is white on dark and translucent fills` (line 159-165), add:

```kotlin
        assertEquals(Color.White, tabLabelColor(WaitingFlashDark))           // ~0.10
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:testDebugUnitTest --tests "relay.feature.workspace.ui.SessionTabsLogicTest"`
Expected: PASS (all tests green).

- [ ] **Step 8: Commit**

```bash
git add ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/SessionTabs.kt \
        ClaudeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/ui/SessionTabsLogicTest.kt
git commit -m "feat(android): flash the waiting (idle) session tab bright orange"
```

---

### Task 2: iOS — flash the idle tab orange

**Files:**
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift` (flash-clock gate ~line 144, `needsAttention` ~line 299, `SessionTab.tabBackground` ~line 425)

**Interfaces:**
- Consumes: `coordinator.activeSessions` (`[SessionInfo]`), `coordinator.agentState(for: UUID) -> AgentDetectedState?`, `coordinator.sessionsAwaitingInput` (`Set<UUID>`); `AgentDetectedState` cases `.idle`/`.blocked`/`.working`/`.unknown`.
- Produces: a new computed `private var anyTabNeedsFlash: Bool` on the view; `SessionTab` gains two `static let` colors and a flashing `.idle` branch.

There is no unit-test target for this SwiftUI view (the logic is `private`), so this task is verified by build + visual inspection rather than a new test. This mirrors how the existing blocked-flash behavior is verified.

- [ ] **Step 1: Add the `anyTabNeedsFlash` helper**

In `ActiveTerminalView.swift`, add this computed property to the view (place it just above `sessionTabBar(flashOn:)` at line 286):

```swift
    /// True when any active session's tab should be flashing — a blocked or
    /// waiting (idle) agent via fine-grained state, or the legacy awaiting-input
    /// set when no fine-grained state is reported. Gates the flash TimelineView.
    private var anyTabNeedsFlash: Bool {
        coordinator.activeSessions.contains { session in
            if let state = coordinator.agentState(for: session.id) {
                return state == .blocked || state == .idle
            }
            return coordinator.sessionsAwaitingInput.contains(session.id)
        }
    }
```

- [ ] **Step 2: Widen the flash-clock gate**

Replace the gate at lines 144-151:

```swift
                if coordinator.sessionsAwaitingInput.isEmpty {
                    sessionTabBar(flashOn: false)
                } else {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let flashOn = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                        sessionTabBar(flashOn: flashOn)
                    }
                }
```

with:

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

- [ ] **Step 3: Widen `needsAttention` to include idle**

In `sessionTabBar(flashOn:)`, replace the `needsAttention` computation at lines 299-301:

```swift
                        let needsAttention = agentState != nil
                            ? agentState == .blocked
                            : coordinator.sessionsAwaitingInput.contains(session.id)
```

with:

```swift
                        let needsAttention = agentState != nil
                            ? (agentState == .blocked || agentState == .idle)
                            : coordinator.sessionsAwaitingInput.contains(session.id)
```

- [ ] **Step 4: Add the waiting colors and flash the idle branch**

In the `SessionTab` struct, add two static colors just above `tabBackground` (before line 420):

```swift
    /// Bright orange for a session waiting on the user (idle), flashing to the
    /// dark below. Motion distinguishes it from Claude's steady amber working fill.
    static let waitingOrange = SwiftUI.Color(red: 1.0, green: 0.584, blue: 0.0)   // #FF9500
    static let waitingFlashDark = SwiftUI.Color(red: 0.102, green: 0.102, blue: 0.102) // #1A1A1A
```

Then change the `.idle` branch inside `tabBackground` (line 429) from:

```swift
            case .idle:    return .yellow
```

to:

```swift
            case .idle:    return flashOn ? SessionTab.waitingOrange : SessionTab.waitingFlashDark
```

- [ ] **Step 5: Build the iOS app**

Run the SPM build to catch any compile error in shared code, then build the app target:

```bash
swift build
xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelay -destination 'generic/platform=iOS' -skipMacroValidation build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED` (or `swift build` clean if the Xcode build is not available in this environment — note it and proceed to visual verification).

- [ ] **Step 6: Commit**

```bash
git add ClaudeRelayApp/Views/ActiveTerminalView.swift
git commit -m "feat(ios): flash the waiting (idle) session tab bright orange"
```

---

### Task 3: Cross-platform visual verification

**Files:** none (verification only).

- [ ] **Step 1: Verify Android in an emulator or device**

Build/run the Android app. Drive a session so the agent finishes its turn (state → `idle`, sidebar pill reads "Waiting"). Confirm:
- The waiting tab pulses bright orange ↔ dark at ~2 Hz.
- A working Claude session's tab stays solid orange (no pulse).
- A blocked session's tab still pulses red.
- The tab number stays legible through the whole flash (black on orange, white on dark).

- [ ] **Step 2: Verify iOS in the simulator**

Same four checks as Step 1 on iOS.

- [ ] **Step 3: Confirm no regression to blocked/working/unknown**

On both platforms, sanity-check that `.blocked` (red flash), `.working` (steady agent color), and `.unknown` (gray) are unchanged from before.

---

## Self-Review

**Spec coverage:**
- idle → orange flash: Task 1 (Android), Task 2 (iOS). ✓
- blocked unchanged (red): untouched branches; verified in Task 3 Step 3. ✓
- working solid: untouched; verified Task 3. ✓
- top strip only: only `SessionTabs.kt` / `ActiveTerminalView.swift` touched; sidebar files not modified. ✓
- iOS flash-clock gate widened: Task 2 Steps 1-2. ✓
- both platforms ~2 Hz identical color: same `#FF9500`/`#1A1A1A` in Tasks 1 & 2. ✓
- label legibility: Task 1 Step 6 (Android test); iOS uses `.contrastingLabel` automatically, verified Task 3. ✓

**Placeholder scan:** none — every code step shows exact edits.

**Type consistency:** `WaitingOrange`/`WaitingFlashDark` (Kotlin) and `waitingOrange`/`waitingFlashDark` (Swift) defined before use; `tabBackground` signature unchanged (color logic only); `anyTabNeedsFlash` defined in Task 2 Step 1 and consumed in Step 2. ✓
