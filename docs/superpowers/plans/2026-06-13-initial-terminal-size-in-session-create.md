# Initial Terminal Size in `session_create` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry the client's best-known terminal size in `session_create` so the PTY forks at the correct width, eliminating zsh's stray `PROMPT_EOL_MARK` `%` on the first prompt.

**Architecture:** Add optional `cols`/`rows` to the `session_create` message in both the Swift and Kotlin protocols. The server forwards them to `SessionManager.createSession` (which already defaults to 80×24 when absent). The Swift coordinator (iOS + macOS) and the Android `SessionCoordinator` each cache the last-known terminal size from resize events and pass it at create time, omitting it when no size is known yet.

**Tech Stack:** Swift (ClaudeRelayKit protocol, ClaudeRelayServer, ClaudeRelayClient shared by iOS+macOS), Kotlin (ClaudeRelayAndroid core-protocol/core-net/core-session/feature-workspace), Swift Testing / XCTest, JUnit.

---

## File Structure

**Swift protocol** — `Sources/ClaudeRelayKit/Protocol/ClientMessage.swift`
Add `cols`/`rows` associated values to `.sessionCreate`; encode/decode them optionally.

**Server** — `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift` + `SessionRequestHandlers.swift`
Thread cols/rows from the decoded message into `createSession`.

**Swift client** — `Sources/ClaudeRelayClient/SessionController.swift`, `ViewModels/SharedSessionCoordinator.swift`, `ViewModels/TerminalViewModel.swift`
`createSession(name:cols:rows:)`; coordinator caches `lastKnownTerminalSize` via a VM `onResize` callback and passes it at create.

**Kotlin protocol** — `core-protocol/.../ClientMessage.kt` + `MessageEnvelope.kt`
Add nullable `cols`/`rows` to `SessionCreate`; emit only when non-null.

**Kotlin client** — `core-net/.../SessionController.kt`, `core-session/.../SessionCoordinator.kt`, `feature-workspace/.../WorkspaceViewModel.kt`
`createSession(name, cols, rows)`; `SessionCoordinator` caches last size; `WorkspaceViewModel.sendResize` records it.

---

## Task 1: Swift protocol — optional cols/rows in `.sessionCreate`

**Files:**
- Modify: `Sources/ClaudeRelayKit/Protocol/ClientMessage.swift:6` (case), `:64-65` (encode), `:101-103` (decode)
- Test: `Tests/ClaudeRelayKitTests/` (existing protocol/envelope test target — add a test file `ClientMessageSessionCreateTests.swift`)

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelayKitTests/ClientMessageSessionCreateTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayKit

final class ClientMessageSessionCreateTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testSessionCreateRoundTripsWithSize() throws {
        let msg = ClientMessage.sessionCreate(name: "dev", cols: 120, rows: 40)
        let env = MessageEnvelope(message: .client(msg))
        let data = try encoder.encode(env)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(.sessionCreate(let name, let cols, let rows)) = decoded.message else {
            return XCTFail("expected sessionCreate, got \(decoded.message)")
        }
        XCTAssertEqual(name, "dev")
        XCTAssertEqual(cols, 120)
        XCTAssertEqual(rows, 40)
    }

    func testSessionCreateRoundTripsWithoutSize() throws {
        let msg = ClientMessage.sessionCreate(name: "dev")
        let env = MessageEnvelope(message: .client(msg))
        let data = try encoder.encode(env)
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(.sessionCreate(let name, let cols, let rows)) = decoded.message else {
            return XCTFail("expected sessionCreate, got \(decoded.message)")
        }
        XCTAssertEqual(name, "dev")
        XCTAssertNil(cols)
        XCTAssertNil(rows)
    }

    func testLegacySessionCreateJSONWithoutSizeDecodes() throws {
        // A wire payload from an old client carries name only.
        let json = #"{"type":"session_create","payload":{"name":"legacy"}}"#
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .client(.sessionCreate(let name, let cols, let rows)) = decoded.message else {
            return XCTFail("expected sessionCreate")
        }
        XCTAssertEqual(name, "legacy")
        XCTAssertNil(cols)
        XCTAssertNil(rows)
    }
}
```

> Note: confirm the exact `MessageEnvelope` construction API by reading
> `Sources/ClaudeRelayKit/Protocol/MessageEnvelope.swift` first; adjust
> `MessageEnvelope(message: .client(...))` to match the real initializer if it
> differs (e.g. a factory like `MessageEnvelope(.client(msg))`).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClientMessageSessionCreateTests`
Expected: FAIL — compile error, `sessionCreate` has no `cols:rows:` arguments.

- [ ] **Step 3: Update the case declaration**

In `ClientMessage.swift:6`, change:

```swift
    case sessionCreate(name: String? = nil)
```
to:
```swift
    case sessionCreate(name: String? = nil, cols: UInt16? = nil, rows: UInt16? = nil)
```

- [ ] **Step 4: Update encode**

In `ClientMessage.swift` `encodePayload`, replace the `.sessionCreate` arm (currently lines 64-65):

```swift
        case .sessionCreate(let name):
            try container.encodeIfPresent(name, forKey: .name)
```
with:
```swift
        case .sessionCreate(let name, let cols, let rows):
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(cols, forKey: .cols)
            try container.encodeIfPresent(rows, forKey: .rows)
```

- [ ] **Step 5: Update decode**

In `ClientMessage.swift` `decode`, replace the `"session_create"` arm (currently lines 101-103):

```swift
        case "session_create":
            let name = try container.decodeIfPresent(String.self, forKey: .name)
            return .sessionCreate(name: name)
```
with:
```swift
        case "session_create":
            let name = try container.decodeIfPresent(String.self, forKey: .name)
            let cols = try container.decodeIfPresent(UInt16.self, forKey: .cols)
            let rows = try container.decodeIfPresent(UInt16.self, forKey: .rows)
            return .sessionCreate(name: name, cols: cols, rows: rows)
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter ClientMessageSessionCreateTests`
Expected: PASS (3 tests).

- [ ] **Step 7: Build the whole package to catch other `.sessionCreate` matches**

Run: `swift build`
Expected: build errors anywhere that pattern-matches `.sessionCreate(let name)` exhaustively. Fix each by widening to `.sessionCreate(let name, _, _)`. The known callsites are the server handler (Task 2) and `SessionController` (Task 3) — those are addressed there. Re-run until `swift build` is clean for code outside those two files.

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeRelayKit/Protocol/ClientMessage.swift Tests/ClaudeRelayKitTests/ClientMessageSessionCreateTests.swift
git commit -m "feat(protocol): add optional cols/rows to session_create (Swift)"
```

---

## Task 2: Server — forward cols/rows into `createSession`

**Files:**
- Modify: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift:186-187`
- Modify: `Sources/ClaudeRelayServer/Network/SessionRequestHandlers.swift:21-32`
- Test: `Tests/ClaudeRelayServerTests/` — add to the existing session handler/manager test suite (`SessionManagerTests` covers `createSession`).

- [ ] **Step 1: Write the failing test**

Add to the server test target (e.g. `Tests/ClaudeRelayServerTests/SessionManagerTests.swift`) — this verifies the size is honored end-to-end at the manager (the handler just forwards):

```swift
func testCreateSessionHonorsExplicitSize() async throws {
    let mgr = makeSessionManager() // existing helper in this suite
    let info = try await mgr.createSession(tokenId: "tok", name: "sz", cols: 132, rows: 50)
    XCTAssertEqual(info.cols, 132)
    XCTAssertEqual(info.rows, 50)
}

func testCreateSessionDefaultsTo80x24WhenSizeOmitted() async throws {
    let mgr = makeSessionManager()
    let info = try await mgr.createSession(tokenId: "tok", name: "sz")
    XCTAssertEqual(info.cols, 80)
    XCTAssertEqual(info.rows, 24)
}
```

> Note: read `Tests/ClaudeRelayServerTests/SessionManagerTests.swift` to reuse
> its existing setup helper (the real name may differ from `makeSessionManager()`).
> `createSession` already accepts `cols:`/`rows:` with 80×24 defaults, so
> `testCreateSessionDefaultsTo80x24WhenSizeOmitted` should pass immediately and
> `testCreateSessionHonorsExplicitSize` should also pass at the manager layer —
> these guard against regression while the handler wiring changes below.

- [ ] **Step 2: Run tests to verify status**

Run: `swift test --filter SessionManagerTests`
Expected: both new tests PASS (manager already supports size). If `makeSessionManager` helper name is wrong, fix the test to match the suite's helper, then re-run.

- [ ] **Step 3: Widen the handler signature**

In `SessionRequestHandlers.swift:21`, change:

```swift
    func handleSessionCreate(name: String?, context: ChannelHandlerContext) {
```
to:
```swift
    func handleSessionCreate(name: String?, cols: UInt16?, rows: UInt16?, context: ChannelHandlerContext) {
```

- [ ] **Step 4: Pass size into `createSession`**

In `SessionRequestHandlers.swift:28`, change:

```swift
                let info = try await mgr.createSession(tokenId: tokenId, name: name)
```
to:
```swift
                let info = try await mgr.createSession(
                    tokenId: tokenId,
                    name: name,
                    cols: cols ?? 80,
                    rows: rows ?? 24
                )
```

- [ ] **Step 5: Update the call from RelayMessageHandler**

In `RelayMessageHandler.swift:186-187`, change:

```swift
        case .sessionCreate(let name):
            handleSessionCreate(name: name, context: context)
```
to:
```swift
        case .sessionCreate(let name, let cols, let rows):
            handleSessionCreate(name: name, cols: cols, rows: rows, context: context)
```

- [ ] **Step 6: Build and run server tests**

Run: `swift build && swift test --filter SessionManagerTests`
Expected: build clean, tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift Sources/ClaudeRelayServer/Network/SessionRequestHandlers.swift Tests/ClaudeRelayServerTests/SessionManagerTests.swift
git commit -m "feat(server): fork PTY at client-supplied size from session_create"
```

---

## Task 3: Swift client — `createSession(name:cols:rows:)` + size caching

**Files:**
- Modify: `Sources/ClaudeRelayClient/SessionController.swift:102-116`
- Modify: `Sources/ClaudeRelayClient/ViewModels/TerminalViewModel.swift:235-238` (add `onResize` callback)
- Modify: `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift` (`lastKnownTerminalSize`, wire `onResize`, pass at create)
- Test: `Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift` (existing)

- [ ] **Step 1: Widen `SessionController.createSession`**

In `SessionController.swift:102`, change:

```swift
    public func createSession(name: String? = nil) async throws -> UUID {
        let response = try await sendAndWaitForResponse(.sessionCreate(name: name))
```
to:
```swift
    public func createSession(name: String? = nil, cols: UInt16? = nil, rows: UInt16? = nil) async throws -> UUID {
        let response = try await sendAndWaitForResponse(.sessionCreate(name: name, cols: cols, rows: rows))
```

- [ ] **Step 2: Add `onResize` callback to TerminalViewModel and fire it**

In `TerminalViewModel.swift`, add a public callback near the other installed callbacks (after line 60, `onAwaitingInputChanged`):

```swift
    /// Installed by the coordinator. Fires whenever the view reports a new
    /// terminal size, so the coordinator can remember the last-known geometry
    /// to seed the next `session_create`.
    public var onResize: ((UInt16, UInt16) -> Void)?
```

Then in `sendResize` (currently lines 235-238), add the callback fire:

```swift
    public func sendResize(cols: UInt16, rows: UInt16) {
        onResize?(cols, rows)
        guard !isSendingSuppressed else { return }
        Task { try? await connection.sendResize(cols: cols, rows: rows) }
    }
```

> `onResize` fires before the suppression guard on purpose: a resize that
> happens while sends are suppressed (during recovery) still updates the
> coordinator's cached geometry for the next create.

- [ ] **Step 3: Add `lastKnownTerminalSize` to the coordinator and wire `onResize`**

In `SharedSessionCoordinator.swift`, add a stored property near the other published/state vars (e.g. just after `terminalViewModels` at line 109):

```swift
    /// Best-known terminal geometry from the most recent resize on any session.
    /// Seeds `session_create` so the PTY forks at the right width. `nil` until
    /// the first terminal has been laid out.
    public private(set) var lastKnownTerminalSize: (cols: UInt16, rows: UInt16)?
```

In `wireTerminalOutput(to:)` (line 635), add the `onResize` wiring alongside `onTitleChanged`:

```swift
        terminalViewModels[sessionId]?.onResize = { [weak self] cols, rows in
            self?.lastKnownTerminalSize = (cols, rows)
        }
```

- [ ] **Step 4: Pass the cached size at create time**

In `SharedSessionCoordinator.swift` `createNewSession()`, change the create call (currently line 397):

```swift
                let sessionId = try await controller.createSession(name: name)
```
to:
```swift
                let size = self.lastKnownTerminalSize
                let sessionId = try await controller.createSession(
                    name: name, cols: size?.cols, rows: size?.rows
                )
```

- [ ] **Step 5: Write a coordinator test for size seeding**

Add to `Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift`:

```swift
@MainActor
func testResizeUpdatesLastKnownTerminalSize() async {
    let coordinator = makeCoordinator() // existing helper in this suite
    let sessionId = UUID()
    let vm = TerminalViewModel(sessionId: sessionId, connection: coordinator.connection)
    coordinator.terminalViewModels[sessionId] = vm
    coordinator.wireTerminalOutput(to: sessionId)

    vm.sendResize(cols: 100, rows: 30)

    XCTAssertEqual(coordinator.lastKnownTerminalSize?.cols, 100)
    XCTAssertEqual(coordinator.lastKnownTerminalSize?.rows, 30)
}
```

> Note: read `SharedSessionCoordinatorTests.swift` for the real setup helper
> name and how it builds a coordinator with a test connection; adapt
> `makeCoordinator()` accordingly.

- [ ] **Step 6: Build and test**

Run: `swift build && swift test --filter SharedSessionCoordinatorTests`
Expected: build clean, test PASS. `swift build` must now be fully clean (Task 1 Step 7 leftover callsites are all resolved).

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeRelayClient/SessionController.swift Sources/ClaudeRelayClient/ViewModels/TerminalViewModel.swift Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift Tests/ClaudeRelayClientTests/SharedSessionCoordinatorTests.swift
git commit -m "feat(client): seed session_create with last-known terminal size (iOS+macOS)"
```

---

## Task 4: Kotlin protocol — optional cols/rows in `SessionCreate`

**Files:**
- Modify: `ClaudeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/ClientMessage.kt:20-22`
- Modify: `ClaudeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/MessageEnvelope.kt:40-41`
- Test: `ClaudeRelayAndroid/core-protocol/src/test/kotlin/relay/protocol/MessageEnvelopeTest.kt`

- [ ] **Step 1: Write the failing test**

Add to `MessageEnvelopeTest.kt`:

```kotlin
@Test
fun `session_create encodes cols and rows when present`() {
    val env = MessageEnvelope.encode(ClientMessage.SessionCreate("dev", 120u, 40u))
    assertTrue(env.contains("\"cols\":120"))
    assertTrue(env.contains("\"rows\":40"))
    assertTrue(env.contains("\"name\":\"dev\""))
}

@Test
fun `session_create omits cols and rows when null`() {
    val env = MessageEnvelope.encode(ClientMessage.SessionCreate("dev"))
    assertFalse(env.contains("cols"))
    assertFalse(env.contains("rows"))
}
```

> Note: match the existing `MessageEnvelopeTest` style for how it invokes the
> encoder (the suite already encodes other `ClientMessage` cases — mirror that
> exact call, whether it's `MessageEnvelope.encode(...)` or an instance method).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ClaudeRelayAndroid && ./gradlew :core-protocol:testDebugUnitTest --tests "*MessageEnvelopeTest*"`
Expected: FAIL — `SessionCreate` constructor takes only `name`.

- [ ] **Step 3: Widen the data class**

In `ClientMessage.kt:20-22`, change:

```kotlin
    data class SessionCreate(val name: String? = null) : ClientMessage {
        override val typeString get() = "session_create"
    }
```
to:
```kotlin
    data class SessionCreate(
        val name: String? = null,
        val cols: UShort? = null,
        val rows: UShort? = null,
    ) : ClientMessage {
        override val typeString get() = "session_create"
    }
```

- [ ] **Step 4: Emit cols/rows in the envelope encoder**

In `MessageEnvelope.kt:40-41`, change:

```kotlin
                is ClientMessage.SessionCreate ->
                    message.name?.let { put("name", JsonPrimitive(it)) }
```
to:
```kotlin
                is ClientMessage.SessionCreate -> {
                    message.name?.let { put("name", JsonPrimitive(it)) }
                    message.cols?.let { put("cols", JsonPrimitive(it.toInt())) }
                    message.rows?.let { put("rows", JsonPrimitive(it.toInt())) }
                }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ClaudeRelayAndroid && ./gradlew :core-protocol:testDebugUnitTest --tests "*MessageEnvelopeTest*"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ClaudeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/ClientMessage.kt ClaudeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/MessageEnvelope.kt ClaudeRelayAndroid/core-protocol/src/test/kotlin/relay/protocol/MessageEnvelopeTest.kt
git commit -m "feat(protocol): add optional cols/rows to session_create (Kotlin)"
```

---

## Task 5: Android client — cache last size, pass at create

**Files:**
- Modify: `ClaudeRelayAndroid/core-net/src/main/kotlin/relay/net/SessionController.kt:130-137`
- Modify: `ClaudeRelayAndroid/core-session/src/main/kotlin/relay/session/SessionCoordinator.kt` (add `recordTerminalSize`, cache field, pass at `:549`)
- Modify: `ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WorkspaceViewModel.kt:106-122` (record size in `sendResize`)
- Test: `ClaudeRelayAndroid/core-session/src/test/kotlin/relay/session/SessionCoordinatorTest.kt`

- [ ] **Step 1: Widen `SessionController.createSession`**

In `SessionController.kt:130-131`, change:

```kotlin
    suspend fun createSession(name: String? = null): UUID {
        val response = sendAndWaitForResponse(ClientMessage.SessionCreate(name))
```
to:
```kotlin
    suspend fun createSession(name: String? = null, cols: UShort? = null, rows: UShort? = null): UUID {
        val response = sendAndWaitForResponse(ClientMessage.SessionCreate(name, cols, rows))
```

- [ ] **Step 2: Add size cache + recorder to SessionCoordinator**

In `SessionCoordinator.kt`, near the `sessionOpsInFlight` field (around line 536), add:

```kotlin
    /** Best-known terminal geometry (cols to rows) from the latest resize; seeds
     *  the next `session_create`. Null until the first terminal lays out. */
    @Volatile
    private var lastKnownTerminalSize: Pair<UShort, UShort>? = null

    /** Called by the workspace layer whenever the terminal reports a new size. */
    fun recordTerminalSize(cols: Int, rows: Int) {
        if (cols <= 0 || rows <= 0) return
        lastKnownTerminalSize = cols.toUShort() to rows.toUShort()
    }
```

- [ ] **Step 3: Pass cached size at create**

In `SessionCoordinator.kt:549`, change:

```kotlin
                sessionController.createSession(name)
```
to:
```kotlin
                val size = lastKnownTerminalSize
                sessionController.createSession(name, size?.first, size?.second)
```

- [ ] **Step 4: Record size in WorkspaceViewModel.sendResize**

In `WorkspaceViewModel.kt`, in `sendResize` (lines 106-122), after the non-positive guard add the record call:

```kotlin
    fun sendResize(cols: Int, rows: Int) {
        if (cols <= 0 || rows <= 0) return
        coordinator.recordTerminalSize(cols, rows)
        viewModelScope.launch {
            // ... existing body unchanged ...
        }
    }
```

> `recordTerminalSize` is called outside the coroutine/suppression gate on
> purpose — the cache should update even when the live resize send is
> suppressed during recovery (parity with the Swift `onResize` placement).

- [ ] **Step 5: Write the failing test**

Add to `SessionCoordinatorTest.kt`:

```kotlin
@Test
fun `createNewSession sends last-known terminal size`() = runTest {
    val coordinator = makeCoordinator() // existing helper in this suite
    coordinator.recordTerminalSize(110, 35)

    coordinator.createNewSession()

    val sent = fakeSessionController.lastCreateArgs // capture in the test double
    assertEquals(110.toUShort(), sent.cols)
    assertEquals(35.toUShort(), sent.rows)
}
```

> Note: read `SessionCoordinatorTest.kt` for the suite's existing coordinator
> factory and its `SessionController` test double. Add a `lastCreateArgs`
> capture (cols/rows) to that double if it doesn't already record create
> arguments. Match the suite's existing assertion/coroutine-test style.

- [ ] **Step 6: Run tests**

Run: `cd ClaudeRelayAndroid && ./gradlew :core-session:testDebugUnitTest --tests "*SessionCoordinatorTest*"`
Expected: PASS.

- [ ] **Step 7: Build the Android modules touched**

Run: `cd ClaudeRelayAndroid && ./gradlew :core-net:compileDebugKotlin :core-session:compileDebugKotlin :feature-workspace:compileDebugKotlin`
Expected: build clean.

- [ ] **Step 8: Commit**

```bash
git add ClaudeRelayAndroid/core-net/src/main/kotlin/relay/net/SessionController.kt ClaudeRelayAndroid/core-session/src/main/kotlin/relay/session/SessionCoordinator.kt ClaudeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WorkspaceViewModel.kt ClaudeRelayAndroid/core-session/src/test/kotlin/relay/session/SessionCoordinatorTest.kt
git commit -m "feat(android): seed session_create with last-known terminal size"
```

---

## Task 6: Full verification

- [ ] **Step 1: Swift — full build + test**

Run: `swift build && swift test`
Expected: all targets build, all tests pass.

- [ ] **Step 2: Android — full unit tests for touched modules**

Run: `cd ClaudeRelayAndroid && ./gradlew :core-protocol:testDebugUnitTest :core-net:testDebugUnitTest :core-session:testDebugUnitTest`
Expected: all pass.

- [ ] **Step 3: Manual smoke (per the spec's manual test)**

Rebuild the server (`swift run claude-relay restart`), rebuild iOS + macOS apps in Xcode, rebuild the Android app. On each: with one session already open and sized, create a *new* session and confirm there is **no** stray `%` above the first prompt and no visible first-prompt reflow. (A brand-new app launch's very first session may still rely on the post-create resize — this is expected per the spec's cold-start note.)

- [ ] **Step 4: Final commit if any manual-fix tweaks were needed**

```bash
git add -A
git commit -m "chore: verification fixes for initial terminal size in session_create"
```

---

## Self-Review Notes

- **Spec coverage:** Swift protocol (Task 1), Kotlin protocol (Task 4), server forwarding + 80×24 fallback (Task 2), Swift client cache+pass for iOS+macOS (Task 3), Android cache+pass (Task 5), backward-compat legacy-decode test (Task 1 Step 1), manual no-`%` check (Task 6). All spec sections mapped.
- **Type consistency:** `cols`/`rows` are `UInt16?` in Swift end-to-end and `UShort?` in Kotlin end-to-end; server converts nil→80/24 via `?? 80`/`?? 24`. Callback named `onResize` consistently; coordinator field `lastKnownTerminalSize` consistent across Swift; Kotlin uses `lastKnownTerminalSize` + `recordTerminalSize` consistently.
- **Backward compat:** absent fields decode to nil → server defaults 80×24; legacy JSON decode test guards this. `minProtocolVersion` unchanged (stays 0).
