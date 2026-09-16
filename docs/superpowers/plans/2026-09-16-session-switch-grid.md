# Session-Switch Grid Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A session switch (or attach, resume, reload, recovery) on any client renders at the device's grid on the first paint instead of a mis-wrapped frame that only a second refresh repairs.

**Architecture:** Three coupled changes. (1) The wire protocol lets `session_attach` and `session_resume` carry an optional `cols`/`rows` grid, exactly like `session_create` already does. (2) The server applies the requested grid to the PTY **before** it reads the ring buffer and **before** the post-replay `forceRepaint`, and a `resize` that arrives while the connection is unattached is **deferred** (stored on the handler, applied at the next attach/resume) instead of dropped. (3) Every client passes its last known grid on every attach/resume call. Together these close the race documented in memory `session-switch-resize-race`: the Swift coordinator publishes the new selection before the awaited detach+resume, so the incoming view's `resize` lands in the unattached window and is dropped; the server then repaints at the previous device's width.

**Tech Stack:** Swift 6 / SwiftNIO (server + CodeRelayKit + CodeRelayClient), Kotlin (shared Android/Linux modules `core-protocol`, `core-net`, `core-session`), XCTest, kotlin.test + `runTest`.

**Spec:** No standalone spec. The investigation report is the authority: `/tmp/pr57-review/garble-swift-report.md`, `/tmp/pr57-review/garble-kotlin-report.md` and the memory note `~/.claude/projects/-Users-miguelriotinto-Developer-CodeRelay/memory/session-switch-resize-race.md`. Root cause, verbatim: "attach/resume carry no grid; the Swift client's switch resize is dropped while unattached; no client re-sends after attach; the server repaints at the PTY's stale width."

## Global Constraints

- **Backward compatible wire format.** `cols`/`rows` on `session_attach`/`session_resume` are optional and **omitted from the JSON when nil** (`encodeIfPresent` in Swift, `?.let { put(...) }` in Kotlin). Old clients and old servers keep working unchanged. No `protocolVersion` bump.
- **Unattached-request reply rule (binding, see the header of `Sources/CodeRelayServer/Network/SessionRequestHandlers.swift`):** a fire-and-forget request must never be answered with `.error`. The deferred-resize path stays **silent** (debug log only, no `resize_ack`, no `error`).
- **Ordering on the server:** resize to the requested grid → `readBuffer()` → replay → `wirePTYOutput(repaintAfter: true)`. The `forceRepaint` wiggle is unchanged.
- **Never log terminal text, prompts, drafts or secrets.** Log lines may carry `cols x rows` and session ids only.
- **Git hygiene:** `git add` explicit paths only (never `-A`/`.`); never `git stash`, `git checkout --`, `git clean`; commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Do not commit `Package.resolved` changes. No `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`/Android `versionCode`/`versionName` edits.
- **Gates:** Swift: `swift test 2>&1 | tail -5; echo EXIT=${pipestatus[1]}` must print `EXIT=0` (a piped `tail` hides a crash — never report "passed" without `EXIT=0`). Kotlin shared modules: from `CodeRelayAndroid/`, `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew --no-daemon :core-protocol:test :core-net:test :core-session:test`. Linux JVM gate (Task 4 only): from `CodeRelayLinux/`, `JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew --no-daemon -x :linux-terminal:buildNativeTerminal :shared-protocol:test :shared-net:test :shared-session:test :app:compileKotlin`.
- **Never run the relay server binary directly** and never `swift run` against the live server. Tests only.
- **SwiftLint** (`swiftlint lint --quiet` from the repo root) must add no new warnings in touched files; file-length ceilings are why server tests go in a **new** file.

---

### Task 1: Kit protocol — optional grid on `session_attach` / `session_resume`

**Files:**
- Modify: `Sources/CodeRelayKit/Protocol/ClientMessage.swift:7,12` (cases), `:98-103` (encode), `:159-165` (decode)
- Test: `Tests/CodeRelayKitTests/ClientMessageAttachGridTests.swift` (new)

**Interfaces:**
- Produces: `case sessionAttach(sessionId: UUID, cols: UInt16? = nil, rows: UInt16? = nil)` and `case sessionResume(sessionId: UUID, skipReplay: Bool = false, cols: UInt16? = nil, rows: UInt16? = nil)`. Tasks 2 and 3 pattern-match on these exact labels and order.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeRelayKitTests/ClientMessageAttachGridTests.swift` (same base class as `ClientMessageSessionCreateTests.swift`):

```swift
import XCTest
@testable import CodeRelayKit

/// The optional `cols`/`rows` grid on `session_attach` and `session_resume`
/// (the session-switch garble fix). Absent fields must decode as nil and nil
/// fields must be omitted from the JSON, so old clients and servers interoperate.
final class ClientMessageAttachGridTests: ProtocolTestCase {

    func testSessionAttachRoundTripsWithGrid() throws {
        let id = UUID()
        let data = try encoder.encode(MessageEnvelope.client(.sessionAttach(sessionId: id, cols: 100, rows: 30)))
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(.sessionAttach(let sid, let cols, let rows)) = decoded else {
            XCTFail("Expected sessionAttach"); return
        }
        XCTAssertEqual(sid, id)
        XCTAssertEqual(cols, 100)
        XCTAssertEqual(rows, 30)
    }

    func testSessionAttachOmitsGridWhenNil() throws {
        let id = UUID()
        let data = try encoder.encode(MessageEnvelope.client(.sessionAttach(sessionId: id)))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("cols"), json)
        XCTAssertFalse(json.contains("rows"), json)
        guard case .client(.sessionAttach(_, let cols, let rows)) = try decoder.decode(MessageEnvelope.self, from: data) else {
            XCTFail("Expected sessionAttach"); return
        }
        XCTAssertNil(cols)
        XCTAssertNil(rows)
    }

    func testSessionResumeRoundTripsWithGridAndSkipReplay() throws {
        let id = UUID()
        let data = try encoder.encode(MessageEnvelope.client(.sessionResume(sessionId: id, skipReplay: true, cols: 80, rows: 24)))
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        guard case .client(.sessionResume(let sid, let skip, let cols, let rows)) = decoded else {
            XCTFail("Expected sessionResume"); return
        }
        XCTAssertEqual(sid, id)
        XCTAssertTrue(skip)
        XCTAssertEqual(cols, 80)
        XCTAssertEqual(rows, 24)
    }

    func testLegacySessionResumeJSONWithoutGridDecodes() throws {
        let id = UUID()
        let json = #"{"type":"session_resume","payload":{"sessionId":"\#(id.uuidString)"}}"#
        guard case .client(.sessionResume(let sid, let skip, let cols, let rows)) =
                try decoder.decode(MessageEnvelope.self, from: Data(json.utf8)) else {
            XCTFail("Expected sessionResume"); return
        }
        XCTAssertEqual(sid, id)
        XCTAssertFalse(skip)
        XCTAssertNil(cols)
        XCTAssertNil(rows)
    }

    func testSessionResumeOmitsGridWhenNil() throws {
        let data = try encoder.encode(MessageEnvelope.client(.sessionResume(sessionId: UUID())))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("cols"), json)
        XCTAssertFalse(json.contains("rows"), json)
        XCTAssertFalse(json.contains("skipReplay"), json)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E 'error:' | head`
Expected: compile errors on the new cases (`extra argument 'cols'`).

- [ ] **Step 3: Implement**

In `ClientMessage.swift`:

```swift
case sessionAttach(sessionId: UUID, cols: UInt16? = nil, rows: UInt16? = nil)
...
/// `skipReplay`: see the resume doc. `cols`/`rows`: the requesting device's
/// grid, applied by the server BEFORE the ring buffer is read and BEFORE the
/// post-replay repaint, so the first frame is drawn for the right width.
/// Optional and omitted when nil for older servers.
case sessionResume(sessionId: UUID, skipReplay: Bool = false, cols: UInt16? = nil, rows: UInt16? = nil)
```

Encode:

```swift
case .sessionAttach(let sessionId, let cols, let rows):
    try container.encode(sessionId, forKey: .sessionId)
    try container.encodeIfPresent(cols, forKey: .cols)
    try container.encodeIfPresent(rows, forKey: .rows)
case .sessionResume(let sessionId, let skipReplay, let cols, let rows):
    try container.encode(sessionId, forKey: .sessionId)
    if skipReplay { try container.encode(true, forKey: .skipReplay) }
    try container.encodeIfPresent(cols, forKey: .cols)
    try container.encodeIfPresent(rows, forKey: .rows)
```

Decode:

```swift
case "session_attach":
    let sessionId = try container.decode(UUID.self, forKey: .sessionId)
    let cols = try container.decodeIfPresent(UInt16.self, forKey: .cols)
    let rows = try container.decodeIfPresent(UInt16.self, forKey: .rows)
    return .sessionAttach(sessionId: sessionId, cols: cols, rows: rows)
case "session_resume":
    let sessionId = try container.decode(UUID.self, forKey: .sessionId)
    let skipReplay = try container.decodeIfPresent(Bool.self, forKey: .skipReplay) ?? false
    let cols = try container.decodeIfPresent(UInt16.self, forKey: .cols)
    let rows = try container.decodeIfPresent(UInt16.self, forKey: .rows)
    return .sessionResume(sessionId: sessionId, skipReplay: skipReplay, cols: cols, rows: rows)
```

Then fix every pattern match that breaks: `grep -rn 'case .sessionAttach(let\|case .sessionResume(let' Sources Tests` — at minimum `Sources/CodeRelayServer/Network/RelayMessageHandler.swift:277-280` (change to `case .sessionAttach(let sessionId, let cols, let rows): handleSessionAttach(sessionId: sessionId, cols: cols, rows: rows, context: context)` and `case .sessionResume(let sessionId, let skipReplay, let cols, let rows): handleSessionResume(sessionId: sessionId, skipReplay: skipReplay, cols: cols, rows: rows, context: context)`). **For this task only**, give `handleSessionAttach`/`handleSessionResume` the new `cols: UInt16?, rows: UInt16?` parameters and leave them unused with a `// Task 2 applies these.` comment so the target compiles; Task 2 wires them. Add `_` wildcards to any other matches that don't need the grid.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter 'ClientMessageAttachGridTests|ClientMessageSessionCreateTests|ClientMessageTests' 2>&1 | tail -3; echo EXIT=${pipestatus[1]}`
Expected: all pass, `EXIT=0`. Then `swift build --build-tests 2>&1 | grep -c 'error:'` → `0`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeRelayKit/Protocol/ClientMessage.swift Sources/CodeRelayServer/Network/RelayMessageHandler.swift Sources/CodeRelayServer/Network/SessionRequestHandlers.swift Tests/CodeRelayKitTests/ClientMessageAttachGridTests.swift
git commit -m "feat(kit): optional cols/rows on session_attach and session_resume

Attach and resume can now carry the requesting device's grid, exactly as
session_create already does. Omitted when nil, so the wire format stays
backward compatible in both directions.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Server — apply the requested grid before replay, defer unattached resizes

**Files:**
- Modify: `Sources/CodeRelayServer/Network/RelayMessageHandler.swift:17-18` (add `pendingGrid`), `cleanupSession` (clear it)
- Modify: `Sources/CodeRelayServer/Network/SessionRequestHandlers.swift:1-40` (header), `handleSessionAttach` (~133), `handleSessionResume` (~180), `handleResize` (~325)
- Modify: `Tests/CodeRelayServerTests/SessionManagerTestCase.swift:93` (`MockPTYSession.resize` records calls + ordering flags)
- Test: `Tests/CodeRelayServerTests/AttachGridTests.swift` (new — `ReplayRepaintTests.swift` is at its SwiftLint length ceiling)
- Modify: `CLAUDE.md` (root, "Wire Protocol" → Scrollback replay paragraph and the `sendAndWaitForResponse` corollary paragraph), `Sources/CodeRelayServer/CLAUDE.md` (a short "Attach grid" note next to the repaint/resize material)

**Interfaces:**
- Consumes: Task 1's `handleSessionAttach(sessionId:cols:rows:context:)` / `handleSessionResume(sessionId:skipReplay:cols:rows:context:)` signatures and dispatch.
- Produces: `var pendingGrid: (cols: UInt16, rows: UInt16)?` on `RelayMessageHandler`; `MockPTYSession.resizeCalls: [(cols: UInt16, rows: UInt16)]`, `readBufferSawResize: Bool`, `forceRepaintSawResize: Bool`.

- [ ] **Step 1: Extend the mock PTY**

In `Tests/CodeRelayServerTests/SessionManagerTestCase.swift`, in `MockPTYSession`:

```swift
/// Test hooks for the attach-grid ordering (AttachGridTests): every resize,
/// plus whether the buffer read and the repaint happened AFTER a resize.
private(set) var resizeCalls: [(cols: UInt16, rows: UInt16)] = []
private(set) var readBufferSawResize = false
private(set) var forceRepaintSawResize = false

func resize(cols: UInt16, rows: UInt16) { resizeCalls.append((cols, rows)) }
func readBuffer() -> Data {
    readBufferSawResize = !resizeCalls.isEmpty
    return bufferContents
}
func forceRepaint() {
    forceRepaintCallCount += 1
    forceRepaintSawOutputHandler = outputHandler != nil
    forceRepaintSawResize = !resizeCalls.isEmpty
}
```

(Replace the existing no-op `resize`, `readBuffer` and `forceRepaint` bodies; keep every other member.)

- [ ] **Step 2: Write the failing tests**

Create `Tests/CodeRelayServerTests/AttachGridTests.swift`. Copy the fixture set-up of `ReplayRepaintTests.testAttachAndResumeForceRepaintAfterOutputIsWired` (temp dir, event loop group, random ports, `TokenStore`, `SessionManager` with the `MockPTYSession` factory, create + attach + detach to obtain `mockPTY`, `WebSocketServer.start()`, `RelayConnection` + `SessionController`, connect + authenticate) into a private `makeFixture()` helper returning `(controller, connection, mockPTY, sessionId, server, group, tempDir)`, then:

```swift
/// Attach with a grid: the PTY is resized to it BEFORE the ring buffer is
/// read and BEFORE the post-replay repaint, so both the replayed bytes'
/// re-wrap and the SIGWINCH redraw happen at the requesting device's width.
@MainActor
func testAttachWithGridResizesBeforeReplayAndRepaint() async throws {
    let f = try await makeFixture()
    defer { f.teardown() }

    try await f.controller.attachSession(id: f.sessionId, cols: 100, rows: 30)
    try? await Task.sleep(for: .milliseconds(200))

    let calls = await f.mockPTY.resizeCalls
    XCTAssertEqual(calls.map { [$0.cols, $0.rows] }, [[100, 30]])
    let readAfter = await f.mockPTY.readBufferSawResize
    XCTAssertTrue(readAfter, "the ring buffer must be read after the resize")
    let repaintAfter = await f.mockPTY.forceRepaintSawResize
    XCTAssertTrue(repaintAfter, "the repaint must fire after the resize, or it redraws at the stale width")
}

/// Resume with a grid behaves the same (this is the session-switch path).
@MainActor
func testResumeWithGridResizesBeforeReplay() async throws {
    let f = try await makeFixture()
    defer { f.teardown() }

    try await f.controller.resumeSession(id: f.sessionId, skipReplay: true, cols: 90, rows: 40)
    try? await Task.sleep(for: .milliseconds(200))

    let calls = await f.mockPTY.resizeCalls
    XCTAssertEqual(calls.map { [$0.cols, $0.rows] }, [[90, 40]])
    let repaintAfter = await f.mockPTY.forceRepaintSawResize
    XCTAssertTrue(repaintAfter)
}

/// A resize that arrives while the connection is unattached (the incoming
/// terminal view laying out during a switch) is deferred, not dropped: the
/// next attach/resume without its own grid applies it. Nothing is replied
/// (no resize_ack, no error) — the unattached-request reply rule.
@MainActor
func testResizeWhileUnattachedIsAppliedByTheNextAttach() async throws {
    let f = try await makeFixture()
    defer { f.teardown() }

    try await f.connection.sendResize(cols: 77, rows: 21)
    try? await Task.sleep(for: .milliseconds(100))
    let before = await f.mockPTY.resizeCalls
    XCTAssertTrue(before.isEmpty, "unattached: nothing to resize yet")

    try await f.controller.attachSession(id: f.sessionId)   // no grid on the request
    try? await Task.sleep(for: .milliseconds(200))

    let calls = await f.mockPTY.resizeCalls
    XCTAssertEqual(calls.map { [$0.cols, $0.rows] }, [[77, 21]], "the deferred grid must be applied at attach")
    let readAfter = await f.mockPTY.readBufferSawResize
    XCTAssertTrue(readAfter)
}

/// The request's own grid wins over a stale deferred one, and the deferred
/// grid is consumed (not re-applied on a later attach).
@MainActor
func testRequestGridBeatsDeferredGridAndConsumesIt() async throws {
    let f = try await makeFixture()
    defer { f.teardown() }

    try await f.connection.sendResize(cols: 77, rows: 21)
    try? await Task.sleep(for: .milliseconds(100))
    try await f.controller.attachSession(id: f.sessionId, cols: 120, rows: 40)
    try? await Task.sleep(for: .milliseconds(200))
    try await f.controller.detach()
    try await f.controller.resumeSession(id: f.sessionId)
    try? await Task.sleep(for: .milliseconds(200))

    let calls = await f.mockPTY.resizeCalls
    XCTAssertEqual(calls.map { [$0.cols, $0.rows] }, [[120, 40]],
                   "only the request grid; the deferred one is neither applied nor replayed later")
}
```

`teardown()` disconnects the connection, stops the server (`Task { try? await server.stop() }`), shuts the group down and removes the temp dir — the same four things the existing test does with `defer`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter AttachGridTests 2>&1 | grep -E 'error|failed|passed' | head; echo EXIT=${pipestatus[1]}`
Expected: compile error — `attachSession(id:cols:rows:)` does not exist yet. **Ruling for the implementer:** Task 3 owns the client `SessionController` signatures, but this task's tests need them. Add them now, minimally, in `Sources/CodeRelayClient/SessionController.swift`:

```swift
public func attachSession(id: UUID, cols: UInt16? = nil, rows: UInt16? = nil) async throws {
    let response = try await sendAndWaitForResponse(
        .sessionAttach(sessionId: id, cols: cols, rows: rows),
        expected: ["session_attached"]
    )
    ... (body unchanged)
}

public func resumeSession(id: UUID, skipReplay: Bool = false, cols: UInt16? = nil, rows: UInt16? = nil) async throws {
    let response = try await sendAndWaitForResponse(
        .sessionResume(sessionId: id, skipReplay: skipReplay, cols: cols, rows: rows),
        expected: ["session_resumed"]
    )
    ... (body unchanged)
}
```

Existing call sites compile unchanged (defaults). Re-run: the four tests must now **fail on assertions** (resizeCalls empty).

- [ ] **Step 4: Implement the server side**

`RelayMessageHandler.swift`, next to `attachedPTY`:

```swift
/// A `resize` that arrived while no session was attached. Clients report
/// their grid the moment the incoming terminal view lays out, which during
/// a switch is the unattached window between `detach` and `resume`; dropping
/// it left the PTY at the previous device's width and the post-replay repaint
/// redrew at that stale width (the "garbled after switching" bug). Consumed
/// by the next attach/resume; a grid on the request itself takes precedence.
/// Event-loop only, like `attachedPTY`.
var pendingGrid: (cols: UInt16, rows: UInt16)?
```

Clear it in `cleanupSession` alongside `attachedPTY = nil`.

`SessionRequestHandlers.swift` — `handleResize`:

```swift
func handleResize(cols: UInt16, rows: UInt16, context: ChannelHandlerContext) {
    guard let pty = attachedPTY else {
        // Deferred, not dropped: applied by the next attach/resume (see
        // `pendingGrid`). Still no reply — resize is fire-and-forget and a
        // `.error` here would resolve whatever RPC is in flight (header).
        pendingGrid = (cols, rows)
        RelayLogger.log(.debug, category: "session", "resize \(cols)x\(rows) deferred until attach")
        return
    }
    ... unchanged ...
}
```

`handleSessionAttach(sessionId:cols:rows:context:)` — on the event loop, before `bridgeToEventLoopWithCtx`:

```swift
let grid: (cols: UInt16, rows: UInt16)? = zip(cols, rows) ?? pendingGrid   // see helper below
pendingGrid = nil
```

Write a small private helper in the same file rather than `zip`:

```swift
/// The grid this attach/resume should apply: the request's own, else one
/// deferred by an unattached `resize`. Consumes the deferred grid either way.
private func takeGrid(cols: UInt16?, rows: UInt16?) -> (cols: UInt16, rows: UInt16)? {
    defer { pendingGrid = nil }
    if let cols, let rows { return (cols, rows) }
    return pendingGrid
}
```

Inside the work closure, immediately after `mgr.attachSession(...)` returns `pty` and **before** `pty.readBuffer()`:

```swift
if let grid { await pty.resize(cols: grid.cols, rows: grid.rows) }
```

Same in `handleSessionResume` after `mgr.resumeSession(...)` and before the `skipReplay ? Data() : await pty.readBuffer()` line (resize even when `skipReplay` is true — the repaint that follows must be at the right width).

In both `onSuccess` closures, right after `handler.attachedPTY = pty`:

```swift
// A resize that arrived while the attach was in flight.
if let late = handler.pendingGrid {
    handler.pendingGrid = nil
    Task { await pty.resize(cols: late.cols, rows: late.rows) }
}
```

(The kernel's own SIGWINCH for that resize makes the app redraw at the new grid, so ordering against the `forceRepaint` Task does not matter.)

Update the log line in the work closure to include the grid when present, e.g. `"Session attached: \(sessionId)" + (grid.map { " grid=\($0.cols)x\($0.rows)" } ?? "")`.

Header comment (lines 1–40): in the paragraph that names the switch race, replace the sentence saying an unattached `resize` is dropped with: "an unattached `resize` is **deferred** into `pendingGrid` and applied by the next attach/resume (still silently); clients also send their grid on the attach/resume request itself, which wins."

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter 'AttachGridTests|ReplayRepaintTests|RelayMessageHandlerTests|SessionHandshakeTests' 2>&1 | tail -3; echo EXIT=${pipestatus[1]}`
Expected: all pass, `EXIT=0`.

- [ ] **Step 6: Docs**

Root `CLAUDE.md`, "Scrollback replay" paragraph — append: "`session_attach`/`session_resume` may carry `cols`/`rows`; the server resizes the PTY to them **before** reading the ring buffer and before the post-replay repaint. A `resize` received while unattached is deferred (`RelayMessageHandler.pendingGrid`) and applied at the next attach/resume rather than dropped — the session-switch race where the incoming view's resize landed between `detach` and `resume`."

Root `CLAUDE.md`, the `sendAndWaitForResponse` corollary paragraph — change "`handleResize`/`handleRefresh` log at debug" to "`handleRefresh` logs at debug; `handleResize` defers the grid into `pendingGrid` and logs at debug".

`Sources/CodeRelayServer/CLAUDE.md` — add a 4–6 line "Attach grid" note near the existing repaint/resize text explaining the ordering invariant (resize → readBuffer → replay → wire → forceRepaint) and why (a redraw produced for width W1 fed into a W2 grid wraps one column short and misplaces the relative cursor moves that follow).

- [ ] **Step 7: Lint, full gate, commit**

Run: `swiftlint lint --quiet Sources/CodeRelayServer/Network Tests/CodeRelayServerTests/AttachGridTests.swift Tests/CodeRelayServerTests/SessionManagerTestCase.swift Sources/CodeRelayClient/SessionController.swift | grep -v '^$' | head` → no new warnings.
Run: `swift test 2>&1 | tail -3; echo EXIT=${pipestatus[1]}` → `EXIT=0`.

```bash
git add Sources/CodeRelayServer/Network/RelayMessageHandler.swift Sources/CodeRelayServer/Network/SessionRequestHandlers.swift Sources/CodeRelayClient/SessionController.swift Tests/CodeRelayServerTests/SessionManagerTestCase.swift Tests/CodeRelayServerTests/AttachGridTests.swift CLAUDE.md Sources/CodeRelayServer/CLAUDE.md
git commit -m "fix(server): apply the requested grid before replay; defer unattached resizes

session_attach/session_resume grids are applied to the PTY before the ring
buffer is read and before the post-replay repaint. A resize that arrives
while unattached — the incoming view laying out during a switch — is kept
in pendingGrid and applied at the next attach/resume instead of dropped.
Still no reply on that path (unattached-request reply rule).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Swift client — send the device grid on every attach/resume

**Files:**
- Modify: `Sources/CodeRelayClient/SessionController.swift` (signatures landed in Task 2; add doc comments)
- Modify: `Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift:729-733` (switch), `:747-750` (switch rollback), `:777` (reload), `:812` (attachRemoteSession), `:855` (attach rollback)
- Modify: `Sources/CodeRelayClient/ViewModels/RecoveryController.swift:304` (recovery restore)
- Test: `Tests/CodeRelayClientTests/SessionControllerGridTests.swift` (new), `Tests/CodeRelayClientTests/SharedSessionCoordinatorGridTests.swift` (new)

**Interfaces:**
- Consumes: `SessionController.attachSession(id:cols:rows:)`, `resumeSession(id:skipReplay:cols:rows:)`; `SharedSessionCoordinator.lastKnownTerminalSize: (cols: UInt16, rows: UInt16)?` (already set from the active VM's `onResize`, line ~1033).
- Produces: a private helper on the coordinator: `var gridForRequest: (cols: UInt16?, rows: UInt16?) { (lastKnownTerminalSize?.cols, lastKnownTerminalSize?.rows) }`.

Design note for the implementer: all terminal view models on one device render in the same pane, so the pane's last reported grid is the right value for every session on that device — no per-VM size store is needed. The incoming view will still send its own `resize` after layout; the server now defers/applies it, so nothing is lost if it differs.

- [ ] **Step 1: Write the failing controller test**

`Tests/CodeRelayClientTests/SessionControllerGridTests.swift` (use `SessionControllerTestCase`'s `FakeConnection`, `Outcome`, `waitUntil`, `deliver` exactly as `SessionControllerForeignErrorTests` does):

```swift
import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

/// attach/resume carry the device grid so the server can resize the PTY before
/// it replays and repaints (the session-switch garble fix).
@MainActor
final class SessionControllerGridTests: SessionControllerTestCase {

    func testResumeSendsTheGridItWasGiven() async throws {
        let conn = FakeConnection()
        let controller = SessionController(connection: conn)
        let target = UUID()
        let request = Task {
            try await controller.resumeSession(id: target, skipReplay: true, cols: 100, rows: 30)
        }
        await waitUntil("the resume to send") { conn.sentTypes == ["session_resume"] }
        guard case .sessionResume(let id, let skip, let cols, let rows) = conn.sentMessages[0] else {
            XCTFail("expected session_resume"); return
        }
        XCTAssertEqual(id, target)
        XCTAssertTrue(skip)
        XCTAssertEqual(cols, 100)
        XCTAssertEqual(rows, 30)
        conn.deliver(.sessionResumed(sessionId: target))
        _ = try await request.value
    }

    func testAttachSendsTheGridItWasGiven() async throws {
        let conn = FakeConnection()
        let controller = SessionController(connection: conn)
        let target = UUID()
        let request = Task { try await controller.attachSession(id: target, cols: 80, rows: 24) }
        await waitUntil("the attach to send") { conn.sentTypes == ["session_attach"] }
        guard case .sessionAttach(let id, let cols, let rows) = conn.sentMessages[0] else {
            XCTFail("expected session_attach"); return
        }
        XCTAssertEqual(id, target)
        XCTAssertEqual(cols, 80)
        XCTAssertEqual(rows, 24)
        conn.deliver(.sessionAttached(sessionId: target, state: "active-attached"))
        _ = try await request.value
    }

    func testAttachWithoutAGridSendsNone() async throws {
        let conn = FakeConnection()
        let controller = SessionController(connection: conn)
        let target = UUID()
        let request = Task { try await controller.attachSession(id: target) }
        await waitUntil("the attach to send") { conn.sentTypes == ["session_attach"] }
        guard case .sessionAttach(_, let cols, let rows) = conn.sentMessages[0] else {
            XCTFail("expected session_attach"); return
        }
        XCTAssertNil(cols)
        XCTAssertNil(rows)
        conn.deliver(.sessionAttached(sessionId: target, state: "active-attached"))
        _ = try await request.value
    }
}
```

(Check `ServerMessage.sessionAttached`'s exact associated labels in `Sources/CodeRelayKit/Protocol/ServerMessage.swift` and adjust the `deliver` lines to match.)

- [ ] **Step 2: Write the failing coordinator test**

`Tests/CodeRelayClientTests/SharedSessionCoordinatorGridTests.swift`. Use the fixture that `SharedSessionCoordinatorOptimizerTests.swift` uses to build a coordinator over a fake connection (read that file first and reuse its helper verbatim — it already authenticates and seeds `sessions`). The test:

```swift
/// The switch path must put the pane's grid on the resume request. The
/// coordinator publishes the new selection BEFORE the awaited detach+resume,
/// so the incoming view's own `resize` lands in the unattached window; the
/// grid on the request is what makes the server replay and repaint at the
/// right width regardless.
func testSwitchToSessionPutsTheLastKnownGridOnTheResume() async throws {
    let (coord, conn) = try await makeAuthenticatedCoordinator(sessions: [sessionA, sessionB])
    // Simulate the terminal view reporting its size once.
    coord.terminalViewModel(for: sessionA.id).sendResize(cols: 104, rows: 33)   // routes via onResize → lastKnownTerminalSize
    try await coord.switchToSession(sessionB.id)   // or whatever the fixture's switch entry point is
    let resume = conn.sentMessages.compactMap { msg -> (UInt16?, UInt16?)? in
        if case .sessionResume(let id, _, let cols, let rows) = msg, id == sessionB.id { return (cols, rows) }
        return nil
    }.last
    XCTAssertEqual(resume?.0, 104)
    XCTAssertEqual(resume?.1, 33)
}
```

Adapt the accessor names to the fixture (the VM accessor is `terminalViewModels[id]`/`terminalViewModel(for:)`; `lastKnownTerminalSize` is `public private(set)` so the test may also assert it directly). If the fixture cannot drive `switchToSession` end-to-end (auth/session-list plumbing), assert the same for `reloadTerminalFromServer(id:)`, which is a single resume, and say so in the report.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter 'SessionControllerGridTests|SharedSessionCoordinatorGridTests' 2>&1 | grep -E 'error|failed|passed' | head; echo EXIT=${pipestatus[1]}`
Expected: controller tests pass already (Task 2 landed the signatures); the coordinator test fails (`cols` nil).

- [ ] **Step 4: Implement**

`SharedSessionCoordinator.swift` — add near `lastKnownTerminalSize`:

```swift
/// The grid to put on attach/resume requests: the pane's last reported size
/// (all sessions on this device share the pane). Nil until the first layout.
var gridForRequest: (cols: UInt16?, rows: UInt16?) {
    (lastKnownTerminalSize?.cols, lastKnownTerminalSize?.rows)
}
```

Then at each call site pass it:

- `:733` → `try await controller.resumeSession(id: id, skipReplay: hasLiveTerminal, cols: gridForRequest.cols, rows: gridForRequest.rows)`
- `:749` → `try? await sessionController?.resumeSession(id: previousId, cols: gridForRequest.cols, rows: gridForRequest.rows)`
- `:777` → `try await withAuth { try await $0.resumeSession(id: id, skipReplay: false, cols: gridForRequest.cols, rows: gridForRequest.rows) }` (capture `let grid = gridForRequest` before the closure if the compiler complains about `self` capture)
- `:812` → `try await controller.attachSession(id: id, cols: gridForRequest.cols, rows: gridForRequest.rows)`
- `:855` → `try? await sessionController?.resumeSession(id: previousId, cols: gridForRequest.cols, rows: gridForRequest.rows)`

`RecoveryController.swift:304` → `try await controller.resumeSession(id: activeId, cols: coordinator.gridForRequest.cols, rows: coordinator.gridForRequest.rows)`.

`SessionController.swift` — extend the two doc comments: "`cols`/`rows`: the device grid; the server resizes the PTY to it before replaying and repainting. Pass the pane's last reported size; nil is allowed for callers that have none."

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter 'SessionControllerGridTests|SharedSessionCoordinatorGridTests|SessionSwitchLatencyTests|RecoveryControllerTests|SessionControllerForeignErrorTests' 2>&1 | tail -3; echo EXIT=${pipestatus[1]}` → `EXIT=0`.
Then the full gate: `swift test 2>&1 | tail -3; echo EXIT=${pipestatus[1]}` → `EXIT=0`.
Lint: `swiftlint lint --quiet Sources/CodeRelayClient Tests/CodeRelayClientTests | head` → no new warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodeRelayClient/SessionController.swift Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift Sources/CodeRelayClient/ViewModels/RecoveryController.swift Tests/CodeRelayClientTests/SessionControllerGridTests.swift Tests/CodeRelayClientTests/SharedSessionCoordinatorGridTests.swift
git commit -m "fix(client): send the pane grid on every attach/resume

The switch path publishes the selection before the awaited detach+resume,
so the incoming view's resize used to land unattached and be dropped; the
server then repainted at the previous device's width. Every attach/resume
now carries lastKnownTerminalSize so the first frame is drawn correctly.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Kotlin (Android + Linux) — protocol fields and coordinator call sites

**Files:**
- Modify: `CodeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/ClientMessage.kt:28,37`
- Modify: `CodeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/MessageEnvelope.kt:46-50`
- Modify: `CodeRelayAndroid/core-net/src/main/kotlin/relay/net/SessionController.kt:264-290`
- Modify: `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/SessionCoordinator.kt:828,868,903,939,1134,1219`
- Test: `CodeRelayAndroid/core-protocol/src/test/kotlin/relay/protocol/MessageEnvelopeTest.kt` (add 3 cases), `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/CoordinatorTestDoubles.kt` (capture grid), `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/SessionCoordinatorTest.kt` (add 1 case)

**Interfaces:**
- Produces: `data class SessionAttach(val sessionId: UUID, val cols: UShort? = null, val rows: UShort? = null)`, `data class SessionResume(val sessionId: UUID, val skipReplay: Boolean = false, val cols: UShort? = null, val rows: UShort? = null)`; `SessionController.attachSession(id, cols: UShort? = null, rows: UShort? = null)`, `resumeSession(id, skipReplay = false, cols: UShort? = null, rows: UShort? = null)`.

- [ ] **Step 1: Write the failing protocol tests**

In `MessageEnvelopeTest.kt`, next to the existing `encode session_resume` tests:

```kotlin
@Test fun `encode session_attach with grid`() {
    val id = UUID.fromString("11111111-2222-3333-4444-555555555555")
    assertEquals(
        """{"type":"session_attach","payload":{"sessionId":"11111111-2222-3333-4444-555555555555","cols":100,"rows":30}}""",
        MessageEnvelope.encodeClient(ClientMessage.SessionAttach(id, cols = 100u, rows = 30u)),
    )
}

@Test fun `encode session_attach omits grid when null`() {
    val id = UUID.fromString("11111111-2222-3333-4444-555555555555")
    assertEquals(
        """{"type":"session_attach","payload":{"sessionId":"11111111-2222-3333-4444-555555555555"}}""",
        MessageEnvelope.encodeClient(ClientMessage.SessionAttach(id)),
    )
}

@Test fun `encode session_resume with skipReplay and grid`() {
    val id = UUID.fromString("11111111-2222-3333-4444-555555555555")
    assertEquals(
        """{"type":"session_resume","payload":{"sessionId":"11111111-2222-3333-4444-555555555555","skipReplay":true,"cols":80,"rows":24}}""",
        MessageEnvelope.encodeClient(ClientMessage.SessionResume(id, skipReplay = true, cols = 80u, rows = 24u)),
    )
}
```

(If the encoder's key order differs from the literal, match the encoder's actual order in the expected string — the existing `SessionCreate` test shows the order the project uses.)

- [ ] **Step 2: Write the failing coordinator test**

`CoordinatorTestDoubles.kt` `FakeConnectionSurface`: add

```kotlin
/** Captured grid from the most recent SessionResume / SessionAttach RPC. */
var lastResumeCols: UShort? = null
var lastResumeRows: UShort? = null
var lastAttachCols: UShort? = null
var lastAttachRows: UShort? = null
```

and in `send()`:

```kotlin
if (message is ClientMessage.SessionResume) {
    lastResumeSkipReplay = message.skipReplay
    lastResumeCols = message.cols
    lastResumeRows = message.rows
}
if (message is ClientMessage.SessionAttach) {
    lastAttachCols = message.cols
    lastAttachRows = message.rows
}
```

`SessionCoordinatorTest.kt`, after the reload test:

```kotlin
@Test
fun `switchToSession puts the last known grid on the resume`() = runTest {
    val log = CallLog()
    val surface = FakeConnectionSurface(log)
    val conn = FakeCoordinatorConnection(log)
    val target = UUID.randomUUID()
    val store = FakeOwnershipStore(log)
    surface.sessionsOnServer = listOf(session(target, "Arya"))
    val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", store, config)

    coord.recordTerminalSize(104, 33)
    coord.switchToSession(target)
    advanceUntilIdle()

    assertTrue("rpc:session_resume" in log)
    assertEquals(104.toUShort(), surface.lastResumeCols,
        "the switch resume must carry the pane grid so the server replays and repaints at this width")
    assertEquals(33.toUShort(), surface.lastResumeRows)
}

@Test
fun `switchToSession before any layout sends no grid`() = runTest {
    val log = CallLog()
    val surface = FakeConnectionSurface(log)
    val conn = FakeCoordinatorConnection(log)
    val target = UUID.randomUUID()
    surface.sessionsOnServer = listOf(session(target, "Arya"))
    val coord = SessionCoordinator(this, conn, SessionController(surface), "tok", FakeOwnershipStore(log), config)

    coord.switchToSession(target)
    advanceUntilIdle()

    assertEquals(null, surface.lastResumeCols)
    assertEquals(null, surface.lastResumeRows)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

From `CodeRelayAndroid/`: `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew --no-daemon :core-protocol:test :core-session:test 2>&1 | grep -E 'error:|FAILED|BUILD' | head`
Expected: compile errors (`cols` is not a parameter of `SessionAttach`).

- [ ] **Step 4: Implement**

`ClientMessage.kt`:

```kotlin
/**
 * [cols]/[rows] (optional): the device grid, applied by the server BEFORE it
 * reads the ring buffer and before the post-replay repaint, so the first frame
 * is drawn for this width. Omitted from the wire when null (older servers).
 */
data class SessionAttach(
    val sessionId: UUID,
    val cols: UShort? = null,
    val rows: UShort? = null,
) : ClientMessage {
    override val typeString get() = "session_attach"
}

data class SessionResume(
    val sessionId: UUID,
    val skipReplay: Boolean = false,
    val cols: UShort? = null,
    val rows: UShort? = null,
) : ClientMessage {
    override val typeString get() = "session_resume"
}
```

`MessageEnvelope.kt` encoder:

```kotlin
is ClientMessage.SessionAttach -> {
    put("sessionId", JsonPrimitive(message.sessionId.toWireString()))
    message.cols?.let { put("cols", JsonPrimitive(it.toInt())) }
    message.rows?.let { put("rows", JsonPrimitive(it.toInt())) }
}
is ClientMessage.SessionResume -> {
    put("sessionId", JsonPrimitive(message.sessionId.toWireString()))
    if (message.skipReplay) put("skipReplay", JsonPrimitive(true))
    message.cols?.let { put("cols", JsonPrimitive(it.toInt())) }
    message.rows?.let { put("rows", JsonPrimitive(it.toInt())) }
}
```

`SessionController.kt`:

```kotlin
suspend fun attachSession(id: UUID, cols: UShort? = null, rows: UShort? = null) {
    val response = sendAndWaitForResponse(
        ClientMessage.SessionAttach(id, cols, rows),
        expected = setOf("session_attached"),
    )
    ... unchanged
}

suspend fun resumeSession(id: UUID, skipReplay: Boolean = false, cols: UShort? = null, rows: UShort? = null) {
    val response = sendAndWaitForResponse(
        ClientMessage.SessionResume(id, skipReplay, cols, rows),
        expected = setOf("session_resumed"),
    )
    ... unchanged
}
```

`SessionCoordinator.kt` — every attach/resume call passes the recorded grid. Add next to `recordTerminalSize`:

```kotlin
/** The grid to put on attach/resume requests (the pane is shared by every session on this device). */
private val gridCols: UShort? get() = lastKnownTerminalSize?.first
private val gridRows: UShort? get() = lastKnownTerminalSize?.second
```

Call sites:
- `:828` → `sessionController.resumeSession(id, skipReplay = false, cols = gridCols, rows = gridRows)`
- `:868` → `sessionController.resumeSession(id, skipReplay = false, cols = gridCols, rows = gridRows)`
- `:903` → `sessionController.attachSession(id, gridCols, gridRows)`
- `:939` → `runCatching { sessionController.resumeSession(previousId, cols = gridCols, rows = gridRows) }`
- `:1134` → `sessionController.resumeSession(activeId, skipReplay = false, cols = gridCols, rows = gridRows)`
- `:1219` → `sessionController.resumeSession(activeId, skipReplay = false, cols = gridCols, rows = gridRows)`

Run `grep -rn 'resumeSession(\|attachSession(' --include='*.kt' CodeRelayAndroid/*/src/main CodeRelayLinux/*/src/main` to catch any other caller (Linux modules compile the same sources; there should be none outside the coordinator and the controller).

- [ ] **Step 5: Run the gates**

Android shared modules (from `CodeRelayAndroid/`): `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew --no-daemon :core-protocol:test :core-net:test :core-session:test :feature-workspace:test :app:assembleDebug 2>&1 | grep -E 'BUILD|FAILED|tests completed' | head` → `BUILD SUCCESSFUL`.
Linux JVM gate (from `CodeRelayLinux/`): `JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew --no-daemon -x :linux-terminal:buildNativeTerminal :shared-protocol:test :shared-net:test :shared-session:test :app:compileKotlin 2>&1 | grep -E 'BUILD|FAILED' | head` → `BUILD SUCCESSFUL`.

- [ ] **Step 6: Commit**

```bash
git add CodeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/ClientMessage.kt CodeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/MessageEnvelope.kt CodeRelayAndroid/core-net/src/main/kotlin/relay/net/SessionController.kt CodeRelayAndroid/core-session/src/main/kotlin/relay/session/SessionCoordinator.kt CodeRelayAndroid/core-protocol/src/test/kotlin/relay/protocol/MessageEnvelopeTest.kt CodeRelayAndroid/core-session/src/test/kotlin/relay/session/CoordinatorTestDoubles.kt CodeRelayAndroid/core-session/src/test/kotlin/relay/session/SessionCoordinatorTest.kt
git commit -m "fix(kotlin): send the pane grid on every attach/resume (Android + Linux)

Mirrors the Swift client: session_attach/session_resume carry the last
recorded terminal size so the server resizes the PTY before replaying and
repainting. Fields are omitted when null for older servers.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
