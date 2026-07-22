# Session State Indicators Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a session's lifecycle state as a left color dot, the friendly coding-agent name and a colored agent-state pill (Waiting/Working/Blocked) to the right of the name (only when an agent is running), across iOS, macOS, and Android — and give macOS a top-bar attach dot + agent pill.

**Architecture:** Add small, unit-testable presentation helpers per language (Swift in `ClaudeRelayClient`; Kotlin in `feature-workspace/ui`): a friendly agent-name map, an agent-state pill, and a `SessionState`→dot-color map. Then rewire the three session rows + the macOS top bar to use them. The tab-icon coloring is already `agentState`-driven (from m32) and needs no change.

**Tech Stack:** SwiftUI (iOS/macOS, shared `ClaudeRelayClient`), Jetpack Compose (Android `feature-workspace`), XCTest, JUnit.

## Global Constraints

- No server or wire-protocol changes. `AgentDetectedState` stays `idle/working/blocked/unknown`.
- "Waiting" is a **display relabel of `.idle`** — never a new enum case.
- Friendly agent names: `claude`→"Claude Code", `codex`→"Codex", `opencode`→"Open Code"; unknown ids fall back to `CodingAgent.find(id:)?.displayName ?? id`.
- Agent name + agent-state pill render **only** when an agent is running (agent id non-nil AND agentState non-nil).
- Agent-state pill colors reuse the existing system: blocked=red, working=`AgentColorPalette.color(for:)`, idle(Waiting)=teal(unseen)/green(seen), unknown=gray.
- Left dot colors: `activeAttached`=green; `activeDetached`/`created`/`starting`/`resuming`=yellow; terminal states not shown in list.
- Row pill is **static**; only the tab icon (iOS/Android) and macOS top-bar pill flash on blocked.
- Android color constants already exist: `QualityGreen 0xFF4CAF50`, `QualityYellow 0xFFFFC107`, `QualityRed 0xFFF44336`, `DoneTeal 0xFF30B0C7`, `UnknownGray 0xFF9E9E9E` (in `ConnectionQualityDot.kt`).
- Swift agent colors: claude=`.orange`, codex/default=`Color(red:84/255,green:132/255,blue:137/255)`.
- Run Swift tests with `swift test`; Android tests with `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:testDebugUnitTest`.

---

### Task 1: Swift friendly agent-name helper

**Files:**
- Create: `Sources/ClaudeRelayClient/Views/AgentDisplayName.swift`
- Test: `Tests/ClaudeRelayClientTests/AgentDisplayNameTests.swift`

**Interfaces:**
- Produces: `enum AgentDisplayName { static func friendly(_ agentId: String?) -> String? }` — nil when agentId is nil; "Open Code" for "opencode"; else `CodingAgent.find(id:)?.displayName ?? agentId`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeRelayClient
import ClaudeRelayKit

final class AgentDisplayNameTests: XCTestCase {
    func testNilForNoAgent() {
        XCTAssertNil(AgentDisplayName.friendly(nil))
    }
    func testClaude() {
        XCTAssertEqual(AgentDisplayName.friendly("claude"), "Claude Code")
    }
    func testCodex() {
        XCTAssertEqual(AgentDisplayName.friendly("codex"), "Codex")
    }
    func testOpencodeIsTwoWords() {
        XCTAssertEqual(AgentDisplayName.friendly("opencode"), "Open Code")
    }
    func testUnknownIdFallsBackToRawId() {
        XCTAssertEqual(AgentDisplayName.friendly("mystery"), "mystery")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AgentDisplayNameTests`
Expected: FAIL — `AgentDisplayName` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import ClaudeRelayKit

/// Presentation-only friendly names for coding agents, layered over the
/// `CodingAgent` registry. The registry stays the data source; this only
/// prettifies for display (e.g. "opencode" → "Open Code").
public enum AgentDisplayName {
    public static func friendly(_ agentId: String?) -> String? {
        guard let agentId else { return nil }
        switch agentId {
        case "opencode": return "Open Code"
        default: return CodingAgent.find(id: agentId)?.displayName ?? agentId
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AgentDisplayNameTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/Views/AgentDisplayName.swift Tests/ClaudeRelayClientTests/AgentDisplayNameTests.swift
git commit -m "feat(client): friendly coding-agent display names"
```

---

### Task 2: Swift SessionState → left-dot color helper

**Files:**
- Create: `Sources/ClaudeRelayClient/Views/SessionStatusDot.swift`
- Test: `Tests/ClaudeRelayClientTests/SessionStatusDotTests.swift`

**Interfaces:**
- Produces: `enum SessionStatusColor { case green, yellow, none }` and `static func bucket(_ state: SessionState) -> SessionStatusColor`; plus a `SessionStatusDot: View` taking `state: SessionState, size: CGFloat = 8` rendering a `Circle` (green/yellow; `.clear` for `.none`).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeRelayClient
import ClaudeRelayKit

final class SessionStatusDotTests: XCTestCase {
    func testAttachedIsGreen() {
        XCTAssertEqual(SessionStatusColor.bucket(.activeAttached), .green)
    }
    func testDetachedIsYellow() {
        XCTAssertEqual(SessionStatusColor.bucket(.activeDetached), .yellow)
    }
    func testTransitionalIsYellow() {
        XCTAssertEqual(SessionStatusColor.bucket(.starting), .yellow)
        XCTAssertEqual(SessionStatusColor.bucket(.resuming), .yellow)
        XCTAssertEqual(SessionStatusColor.bucket(.created), .yellow)
    }
    func testTerminalIsNone() {
        XCTAssertEqual(SessionStatusColor.bucket(.exited), SessionStatusColor.none)
        XCTAssertEqual(SessionStatusColor.bucket(.failed), SessionStatusColor.none)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionStatusDotTests`
Expected: FAIL — `SessionStatusColor` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import SwiftUI
import ClaudeRelayKit

/// Color bucket for the session lifecycle/attachment dot shown left of the
/// session name. Replaces the old lifecycle text pill.
public enum SessionStatusColor: Equatable {
    case green   // activeAttached
    case yellow  // activeDetached / transitional
    case none    // terminal — not shown in the session list

    public static func bucket(_ state: SessionState) -> SessionStatusColor {
        switch state {
        case .activeAttached: return .green
        case .activeDetached, .created, .starting, .resuming: return .yellow
        case .exited, .failed, .terminated, .expired: return .none
        }
    }
}

/// Small lifecycle/attachment dot: green = attached, yellow = detached/transitional.
public struct SessionStatusDot: View {
    public let state: SessionState
    public let size: CGFloat

    public init(state: SessionState, size: CGFloat = 8) {
        self.state = state
        self.size = size
    }

    private var color: Color {
        switch SessionStatusColor.bucket(state) {
        case .green: return .green
        case .yellow: return .yellow
        case .none: return .clear
        }
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .fixedSize()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionStatusDotTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/Views/SessionStatusDot.swift Tests/ClaudeRelayClientTests/SessionStatusDotTests.swift
git commit -m "feat(client): SessionState left-dot color helper + view"
```

---

### Task 3: Swift AgentStatePill (color + word)

**Files:**
- Create: `Sources/ClaudeRelayClient/Views/AgentStatePill.swift`
- Test: `Tests/ClaudeRelayClientTests/AgentStatePillTests.swift`

**Interfaces:**
- Consumes: `AgentColorPalette.color(for:)`.
- Produces:
  - `enum AgentStatePillModel { static func word(_ s: AgentDetectedState) -> String }` — idle→"Waiting", working→"Working", blocked→"Blocked", unknown→"Unknown".
  - `static func color(_ s: AgentDetectedState, agentId: String?, seen: Bool) -> Color` — blocked=.red, working=palette, idle=seen ? .green : .teal, unknown=.gray.
  - `struct AgentStatePill: View` taking `agentState: AgentDetectedState, agentId: String?, seen: Bool` rendering the colored capsule + word.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftUI
@testable import ClaudeRelayClient
import ClaudeRelayKit

final class AgentStatePillTests: XCTestCase {
    func testWords() {
        XCTAssertEqual(AgentStatePillModel.word(.idle), "Waiting")
        XCTAssertEqual(AgentStatePillModel.word(.working), "Working")
        XCTAssertEqual(AgentStatePillModel.word(.blocked), "Blocked")
        XCTAssertEqual(AgentStatePillModel.word(.unknown), "Unknown")
    }
    func testBlockedIsRed() {
        XCTAssertEqual(AgentStatePillModel.color(.blocked, agentId: "claude", seen: true), Color.red)
    }
    func testWorkingUsesAgentPalette() {
        XCTAssertEqual(
            AgentStatePillModel.color(.working, agentId: "claude", seen: true),
            AgentColorPalette.color(for: "claude")
        )
    }
    func testWaitingSeenIsGreenUnseenIsTeal() {
        XCTAssertEqual(AgentStatePillModel.color(.idle, agentId: "claude", seen: true), Color.green)
        XCTAssertEqual(AgentStatePillModel.color(.idle, agentId: "claude", seen: false), Color.teal)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AgentStatePillTests`
Expected: FAIL — `AgentStatePillModel` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import SwiftUI
import ClaudeRelayKit

/// Pure color/word mapping for the agent-state pill. "Waiting" is the display
/// label for `.idle` (agent running, awaiting input).
public enum AgentStatePillModel {
    public static func word(_ s: AgentDetectedState) -> String {
        switch s {
        case .idle: return "Waiting"
        case .working: return "Working"
        case .blocked: return "Blocked"
        case .unknown: return "Unknown"
        }
    }

    public static func color(_ s: AgentDetectedState, agentId: String?, seen: Bool) -> Color {
        switch s {
        case .blocked: return .red
        case .working: return AgentColorPalette.color(for: agentId)
        case .idle: return seen ? .green : .teal
        case .unknown: return .gray
        }
    }
}

/// Colored capsule + text word for a running agent's state.
public struct AgentStatePill: View {
    public let agentState: AgentDetectedState
    public let agentId: String?
    public let seen: Bool

    public init(agentState: AgentDetectedState, agentId: String?, seen: Bool) {
        self.agentState = agentState
        self.agentId = agentId
        self.seen = seen
    }

    public var body: some View {
        let c = AgentStatePillModel.color(agentState, agentId: agentId, seen: seen)
        Text(AgentStatePillModel.word(agentState))
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(c.opacity(0.15))
            .foregroundStyle(c)
            .clipShape(Capsule())
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AgentStatePillTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/Views/AgentStatePill.swift Tests/ClaudeRelayClientTests/AgentStatePillTests.swift
git commit -m "feat(client): AgentStatePill (Waiting/Working/Blocked color + word)"
```

---

### Task 4: iOS session row — left dot + agent name + state pill

**Files:**
- Modify: `ClaudeRelayApp/Views/SessionSidebarView.swift` (SessionRow `body` ~127-164; remove `badgeColor` ~188-194)

**Interfaces:**
- Consumes: `SessionStatusDot`, `AgentDisplayName.friendly`, `AgentStatePill` (Tasks 1-3). `SessionRow` already has `session`, `name`, `shortId`, `agentId`, `agentState`, `seen`, `title`.

- [ ] **Step 1: Replace the SessionRow body**

Replace the `HStack(spacing: 10) { ... }` (lines ~127-164) with:

```swift
        HStack(spacing: 10) {
            SessionStatusDot(state: session.state, size: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let title, !title.isEmpty {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(shortId)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if let agentId, let friendly = AgentDisplayName.friendly(agentId), let agentState {
                Text(friendly)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                AgentStatePill(agentState: agentState, agentId: agentId, seen: seen)
            }
        }
```

- [ ] **Step 2: Remove the now-unused badgeColor**

Delete the `private var badgeColor: SwiftUI.Color { ... }` block (~188-194).

- [ ] **Step 3: Build the iOS app target**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'generic/platform=iOS' -skipMacroValidation build CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -quiet`
Expected: `** BUILD SUCCEEDED **` (no reference to `badgeColor`).

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayApp/Views/SessionSidebarView.swift
git commit -m "feat(ios): session row left dot + agent name + state pill"
```

---

### Task 5: macOS session row — left dot + agent name + state pill

**Files:**
- Modify: `ClaudeRelayMac/Views/SessionSidebarView.swift` (SessionRow `body` ~126-146+)

**Interfaces:**
- Consumes: Tasks 1-3. `SessionRow` has `name`, `shortId`, `agentId`, `agentState`, `seen`, `title`. **Note:** the macOS `SessionRow` currently has NO `session`/`state` field — add a `state: SessionState` parameter and pass `session.state` from the call site (~24-33).

- [ ] **Step 1: Add `state` to SessionRow and its call site**

In the `SessionRow(...)` call (~24-33) add `state: session.state,` after `name:`. In the `private struct SessionRow` field list (~117-124) add `let state: SessionState`.

- [ ] **Step 2: Replace the SessionRow body**

Replace `HStack(spacing: 8) { ActivityDot(...) VStack { ... } }` (~127+) with:

```swift
        HStack(spacing: 8) {
            SessionStatusDot(state: state, size: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(shortId)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let agentId, let friendly = AgentDisplayName.friendly(agentId), let agentState {
                Text(friendly)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                AgentStatePill(agentState: agentState, agentId: agentId, seen: seen)
            }
        }
```

- [ ] **Step 3: Build the macOS app target**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayMac -destination 'generic/platform=macOS' -skipMacroValidation build CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -quiet`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayMac/Views/SessionSidebarView.swift
git commit -m "feat(macos): session row left dot + agent name + state pill"
```

---

### Task 6: macOS top bar — attach dot + agent name + state pill

**Files:**
- Modify: `ClaudeRelayMac/Views/StatusBarView.swift` (the `if let id = coordinator.activeSessionId { ActivityDot(...) }` block ~18-20)

**Interfaces:**
- Consumes: Tasks 1-3. Coordinator accessors: `activeSessionId`, `activeAgent(for:)`, `agentState(for:)`, `isUnseen(_:)`, and `activeSessions` (to find the `SessionInfo` for its `state`).

- [ ] **Step 1: Replace the active-session block**

Replace lines ~18-20 with:

```swift
            if let id = coordinator.activeSessionId {
                if let info = coordinator.activeSessions.first(where: { $0.id == id }) {
                    SessionStatusDot(state: info.state, size: 6)
                }
                let agentId = coordinator.activeAgent(for: id)
                if let agentId, let friendly = AgentDisplayName.friendly(agentId),
                   let agentState = coordinator.agentState(for: id) {
                    Text(friendly)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    AgentStatePill(agentState: agentState, agentId: agentId, seen: !coordinator.isUnseen(id))
                }
            }
```

- [ ] **Step 2: Build the macOS app target**

Run: `xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayMac -destination 'generic/platform=macOS' -skipMacroValidation build CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -quiet`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayMac/Views/StatusBarView.swift
git commit -m "feat(macos): top bar attach dot + agent name + state pill"
```

---

### Task 7: Android friendly agent-name helper

**Files:**
- Create: `ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/AgentDisplayName.kt`
- Test: `ClaudeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/ui/AgentDisplayNameTest.kt`

**Interfaces:**
- Produces: `fun friendlyAgentName(agentId: String?): String?` — null→null; "opencode"→"Open Code"; "claude"→"Claude Code"; "codex"→"Codex"; else the raw id.

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.feature.workspace.ui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AgentDisplayNameTest {
    @Test fun nullForNoAgent() { assertNull(friendlyAgentName(null)) }
    @Test fun claude() { assertEquals("Claude Code", friendlyAgentName("claude")) }
    @Test fun codex() { assertEquals("Codex", friendlyAgentName("codex")) }
    @Test fun opencodeTwoWords() { assertEquals("Open Code", friendlyAgentName("opencode")) }
    @Test fun unknownFallsBack() { assertEquals("mystery", friendlyAgentName("mystery")) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:testDebugUnitTest --tests "relay.feature.workspace.ui.AgentDisplayNameTest"`
Expected: FAIL — unresolved reference `friendlyAgentName`.

- [ ] **Step 3: Write minimal implementation**

```kotlin
package relay.feature.workspace.ui

/**
 * Presentation-only friendly names for coding agents. Mirrors the Swift
 * `AgentDisplayName.friendly` (opencode → "Open Code"). Kept in lockstep with
 * the `CodingAgent` registry display names.
 */
fun friendlyAgentName(agentId: String?): String? = when (agentId) {
    null -> null
    "claude" -> "Claude Code"
    "codex" -> "Codex"
    "opencode" -> "Open Code"
    else -> agentId
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:testDebugUnitTest --tests "relay.feature.workspace.ui.AgentDisplayNameTest"`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/AgentDisplayName.kt ClaudeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/ui/AgentDisplayNameTest.kt
git commit -m "feat(android): friendly coding-agent display names"
```

---

### Task 8: Android agent-state pill (color + word) + SessionState dot color

**Files:**
- Create: `ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/AgentStatePill.kt`
- Test: `ClaudeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/ui/AgentStatePillTest.kt`

**Interfaces:**
- Consumes: `agentColor(agentId)`, `QualityRed`, `QualityGreen`, `DoneTeal`, `UnknownGray`, `QualityYellow` (existing), `WorkspaceLogic.badgeBucket` (existing).
- Produces:
  - `fun agentStateWord(s: AgentDetectedState): String` — IDLE→"Waiting", WORKING→"Working", BLOCKED→"Blocked", UNKNOWN→"Unknown".
  - `fun agentStatePillColor(s: AgentDetectedState, agentId: String?, seen: Boolean): Color`.
  - `fun sessionStatusDotColor(state: SessionState): Color?` — GREEN→QualityGreen, YELLOW→QualityYellow, RED bucket (terminal)→null (not shown).
  - `@Composable fun AgentStatePill(agentState, agentId, seen)` and `@Composable fun SessionStatusDot(state, size)`.

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.feature.workspace.ui

import relay.protocol.AgentDetectedState
import relay.protocol.SessionState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AgentStatePillTest {
    @Test fun words() {
        assertEquals("Waiting", agentStateWord(AgentDetectedState.IDLE))
        assertEquals("Working", agentStateWord(AgentDetectedState.WORKING))
        assertEquals("Blocked", agentStateWord(AgentDetectedState.BLOCKED))
        assertEquals("Unknown", agentStateWord(AgentDetectedState.UNKNOWN))
    }
    @Test fun blockedIsRed() {
        assertEquals(QualityRed, agentStatePillColor(AgentDetectedState.BLOCKED, "claude", true))
    }
    @Test fun workingIsAgentColor() {
        assertEquals(agentColor("claude"), agentStatePillColor(AgentDetectedState.WORKING, "claude", true))
    }
    @Test fun waitingSeenGreenUnseenTeal() {
        assertEquals(QualityGreen, agentStatePillColor(AgentDetectedState.IDLE, "claude", true))
        assertEquals(DoneTeal, agentStatePillColor(AgentDetectedState.IDLE, "claude", false))
    }
    @Test fun dotColorAttachedGreenDetachedYellowTerminalNull() {
        assertEquals(QualityGreen, sessionStatusDotColor(SessionState.ACTIVE_ATTACHED))
        assertEquals(QualityYellow, sessionStatusDotColor(SessionState.ACTIVE_DETACHED))
        assertNull(sessionStatusDotColor(SessionState.EXITED))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:testDebugUnitTest --tests "relay.feature.workspace.ui.AgentStatePillTest"`
Expected: FAIL — unresolved references.

- [ ] **Step 3: Write minimal implementation**

```kotlin
package relay.feature.workspace.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import relay.protocol.AgentDetectedState
import relay.protocol.SessionState

/** Display word for the agent-state pill. IDLE is shown as "Waiting". */
fun agentStateWord(s: AgentDetectedState): String = when (s) {
    AgentDetectedState.IDLE -> "Waiting"
    AgentDetectedState.WORKING -> "Working"
    AgentDetectedState.BLOCKED -> "Blocked"
    AgentDetectedState.UNKNOWN -> "Unknown"
}

/** Pill color, parity with Swift AgentStatePillModel.color. */
fun agentStatePillColor(s: AgentDetectedState, agentId: String?, seen: Boolean): Color = when (s) {
    AgentDetectedState.BLOCKED -> QualityRed
    AgentDetectedState.WORKING -> agentColor(agentId)
    AgentDetectedState.IDLE -> if (seen) QualityGreen else DoneTeal
    AgentDetectedState.UNKNOWN -> UnknownGray
}

/** Left dot color for the session lifecycle/attachment state; null = not shown. */
fun sessionStatusDotColor(state: SessionState): Color? = when (WorkspaceLogic.badgeBucket(state)) {
    WorkspaceLogic.BadgeBucket.GREEN -> QualityGreen
    WorkspaceLogic.BadgeBucket.YELLOW -> QualityYellow
    WorkspaceLogic.BadgeBucket.RED -> null
}

@Composable
fun AgentStatePill(agentState: AgentDetectedState, agentId: String?, seen: Boolean) {
    val c = agentStatePillColor(agentState, agentId, seen)
    Text(
        text = agentStateWord(agentState),
        style = MaterialTheme.typography.labelSmall,
        color = c,
        modifier = Modifier
            .background(color = c.copy(alpha = 0.15f), shape = RoundedCornerShape(50))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}
```

Note: `WorkspaceLogic.badgeBucket` maps `ACTIVE_ATTACHED` AND `ACTIVE_DETACHED` both to GREEN today. That is the OLD pill semantics. Task 8 keeps `badgeBucket` unchanged (used elsewhere) but the left dot needs attached=green / detached=yellow — so add a dedicated mapping instead of reusing badgeBucket. Replace `sessionStatusDotColor` above with:

```kotlin
fun sessionStatusDotColor(state: SessionState): Color? = when (state) {
    SessionState.ACTIVE_ATTACHED -> QualityGreen
    SessionState.ACTIVE_DETACHED, SessionState.CREATED,
    SessionState.STARTING, SessionState.RESUMING -> QualityYellow
    SessionState.EXITED, SessionState.FAILED,
    SessionState.TERMINATED, SessionState.EXPIRED -> null
}
```

(Adjust the test's `ACTIVE_DETACHED` expectation to `QualityYellow` — already done in Step 1.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:testDebugUnitTest --tests "relay.feature.workspace.ui.AgentStatePillTest"`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/AgentStatePill.kt ClaudeRelayAndroid/feature-workspace/src/test/kotlin/relay/feature/workspace/ui/AgentStatePillTest.kt
git commit -m "feat(android): AgentStatePill + SessionState left-dot color"
```

---

### Task 9: Android session row — left dot + agent name + state pill

**Files:**
- Modify: `ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/SessionSidebar.kt` (SessionRow `Row` body ~270-302; remove/keep `StateBadge`)

**Interfaces:**
- Consumes: `friendlyAgentName` (Task 7), `AgentStatePill` (Task 8), `sessionStatusDotColor` (Task 8). `SessionRow` already has `session`, `agentId`, `agentState`, `seen`.

- [ ] **Step 1: Replace the dot + trailing badge in SessionRow**

In `SessionRow` (~248-317), replace the leading `ActivityDot(...)` (line ~271) with a lifecycle dot, and replace the trailing `StateBadge(state = session.state)` (line ~301) with the agent name + pill. The leading dot:

```kotlin
            val dotColor = sessionStatusDotColor(session.state)
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(dotColor ?: Color.Transparent),
            )
```

Replace `StateBadge(state = session.state)` with:

```kotlin
            val friendly = friendlyAgentName(agentId)
            if (friendly != null && agentState != null) {
                Text(
                    text = friendly,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
                AgentStatePill(agentState = agentState, agentId = agentId, seen = seen)
            }
```

Add imports at top: `import androidx.compose.foundation.layout.size`, `import androidx.compose.foundation.shape.CircleShape`, `import androidx.compose.ui.draw.clip`. (Row already imports `Arrangement.spacedBy(10.dp)` spacing which keeps name / pill separated.)

- [ ] **Step 2: Remove the now-unused StateBadge composable**

Delete `private fun StateBadge(...)` (~319-338) since nothing references it now.

- [ ] **Step 3: Build the module**

Run: `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:assembleDebug`
Expected: `BUILD SUCCESSFUL` (no unresolved `StateBadge`/`ActivityDot` in the row).

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/ui/SessionSidebar.kt
git commit -m "feat(android): session row left dot + agent name + state pill"
```

---

### Task 10: Full test + build sweep across all clients

**Files:** none (verification only).

- [ ] **Step 1: Swift package tests**

Run: `swift test`
Expected: all pass, including the new `AgentDisplayNameTests`, `SessionStatusDotTests`, `AgentStatePillTests`.

- [ ] **Step 2: Android unit tests**

Run: `cd ClaudeRelayAndroid && ./gradlew :feature-workspace:testDebugUnitTest`
Expected: all pass, including `AgentDisplayNameTest`, `AgentStatePillTest`, and the existing `tabBackground` tests.

- [ ] **Step 3: iOS + macOS app builds**

Run both:
`xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'generic/platform=iOS' -skipMacroValidation build CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -quiet`
`xcodebuild -project ClaudeRelay.xcodeproj -scheme ClaudeRelayMac -destination 'generic/platform=macOS' -skipMacroValidation build CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -quiet`
Expected: `** BUILD SUCCEEDED **` for both.

- [ ] **Step 4: Commit any incidental fixes, else no-op**

```bash
git commit --allow-empty -m "test: verify state-indicator redesign across all clients"
```

---

## Notes on the tab icon (already done)

Your spec's "tab icon uses the color scheme + flashing" is **already implemented** by the m32 work:
- iOS `SessionTab.tabBackground` and Android `tabBackground(...)` already switch on `agentState` (blocked=red+flash, working=agent color, idle=teal, unknown=gray).
- No change required. Tasks 4/9 only touch the session rows, and Tasks 5/6 the macOS surfaces.

If a future tweak is wanted (e.g. the iOS tab should flash on `agentState==.blocked` rather than the legacy `sessionsAwaitingInput`), that is a separate, small change to the `needsAttention` wiring at `ActiveTerminalView.swift:294` — out of scope here.
