# Agent State Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring herdr-style rich per-session agent state detection (working / blocked / done / idle / unknown, plus a "needs attention" signal and window title) to Code Relay's server and both apps.

**Architecture:** Phase 1 lays the wire + model + state-plumbing groundwork with a new `AgentDetectedState` enum threaded through `sessionActivity`, `SessionInfo`, the server observer chain, and the client `ActivityCoordinator` — all additive and backward-compatible. Phase 2 adds a headless SwiftTerm screen model per session on the server, a manifest-driven `AgentStateDetector` (ported from herdr's TOML rule engine), an anti-flap arbiter in `SessionActivityMonitor`, and richer sidebar UI on iOS + macOS.

**Tech Stack:** Swift 6 / Swift Concurrency (actors), SwiftNIO (server), SwiftTerm 1.2.0 (headless terminal emulation), SwiftUI (apps), XCTest (tests), Codable JSON manifests.

## Global Constraints

- **Wire protocol:** All WebSocket messages use `MessageEnvelope` (`{"type":...,"payload":{...}}`). Type strings must be unique across `ClientMessage.allTypeStrings` and `ServerMessage.allTypeStrings`. `ClientMessage`/`ServerMessage` are only decodable via `MessageEnvelope`.
- **Backward compatibility:** `minProtocolVersion = 0`. Every new wire field is an **optional** encoded with `encodeIfPresent` / decoded with `decodeIfPresent`. An old client must still decode a new server's messages and vice-versa. Never remove or rename an existing field.
- **Date encoding:** WebSocket path uses default `JSONEncoder` (Double timestamps); Admin HTTP uses `.iso8601`. Never mix encoders between the two paths. (This plan touches only the WebSocket path.)
- **Enum evolution:** New `ServerMessage`/enum cases with trailing defaulted associated values keep old *construction* sites compiling, but every `guard case` / pattern-match site that binds the associated values MUST be updated to bind the new ones.
- **SwiftLint** (`.swiftlint.yml`): line_length warning 140 / error 200; type_body_length 350/500; function_body_length 80/150; file_length 500/1000; cyclomatic_complexity 15/25; identifier min length 2. A function returning a 5-member tuple triggers a `large_tuple` **warning** (not error); returning a struct avoids it.
- **Server lifecycle:** Never run the server binary directly or `pkill` it. Use `swift run claude-relay load|start|stop|restart|status`. Tests never start a real server.
- **Build/test commands:** `swift build`; `swift test --filter <SuiteName>` or `swift test --filter <testMethodName>`.
- **Naming / copy:** Wire agent-state raw values are lowercase `idle` / `working` / `blocked` / `unknown` (mirrors herdr's `AgentState`). Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **XcodeGen:** The two apps are XcodeGen-managed via `project.yml`. Adding Swift files under `Sources/ClaudeRelayClient` needs no project regen (SPM target). App-target `.swift` files under `ClaudeRelayApp/` / `ClaudeRelayMac/` are globbed, so new files there are picked up on next Xcode build without `xcodegen`, but editing `project.yml` (Task 6 does NOT — SwiftTerm is added to the SPM server target only) would.

---

## File Structure

**Phase 1 — protocol + plumbing (additive, no behavior change yet):**
- `Sources/ClaudeRelayKit/Models/AgentDetectedState.swift` (new) — the 5-value wire enum.
- `Sources/ClaudeRelayKit/Protocol/ServerMessage.swift` (modify) — widen `sessionActivity`.
- `Sources/ClaudeRelayKit/Models/SessionInfo.swift` (modify) — optional `agentState` / `title`.
- `Sources/ClaudeRelayServer/Actors/SessionActivityMonitor.swift` (modify) — widen `onChange` + getters.
- `Sources/ClaudeRelayServer/Actors/PTYSession.swift` (modify) — widen protocol callback + getters.
- `Sources/ClaudeRelayServer/Actors/SessionManager.swift` (modify) — widen observer typealias / cache.
- `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift` (modify) — widen observer closure.
- `Sources/ClaudeRelayServer/Network/SessionRequestHandlers.swift` (modify) — `ActivitySnapshot` struct.
- `Sources/ClaudeRelayClient/RelayConnection.swift` (modify) — widen `onSessionActivity`.
- `Sources/ClaudeRelayClient/ViewModels/ActivityCoordinator.swift` (modify) — new published maps + `markSeen`.
- `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift` (modify) — thread new fields.

**Phase 2 — detection engine + UI:**
- `Package.swift` (modify) — SwiftTerm dep + `Resources/Agents` on the server target.
- `Sources/ClaudeRelayServer/Detection/TerminalScreenModel.swift` (new) — headless SwiftTerm.
- `Sources/ClaudeRelayServer/Detection/ScreenRegion.swift` (new) — region slicers.
- `Sources/ClaudeRelayServer/Detection/AgentManifest.swift` (new) — Codable rule types.
- `Sources/ClaudeRelayServer/Detection/AgentStateDetector.swift` (new) — rule engine.
- `Sources/ClaudeRelayServer/Resources/Agents/{claude,codex,opencode}.json` (new) — bundled manifests.
- `Sources/ClaudeRelayServer/Actors/SessionActivityMonitor.swift` (modify) — arbiter.
- `Sources/ClaudeRelayServer/Actors/PTYSession.swift` (modify) — feed screen model + snapshot on poll.
- `Sources/ClaudeRelayKit/Models/CodingAgent.swift` (modify) — add `.opencode`.
- `Sources/ClaudeRelayClient/Views/ActivityDot.swift` (modify) — richer rendering.
- `ClaudeRelayApp/Views/SessionSidebarView.swift` / `ClaudeRelayMac/Views/SessionSidebarView.swift` (modify) — labels + titles.

---

# PHASE 1 — Protocol & Plumbing Groundwork

## Task 1: `AgentDetectedState` wire enum

**Files:**
- Create: `Sources/ClaudeRelayKit/Models/AgentDetectedState.swift`
- Test: `Tests/ClaudeRelayKitTests/AgentDetectedStateTests.swift`

**Interfaces:**
- Produces: `public enum AgentDetectedState: String, Codable, Equatable, Sendable { case idle, working, blocked, unknown }`; `public var needsAttention: Bool`; tolerant `init(from:)` mapping unknown raw values to `.unknown`.
- Consumes: nothing (leaf model, mirrors the existing `ActivityState` pattern in the same directory).

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelayKitTests/AgentDetectedStateTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayKit

final class AgentDetectedStateTests: XCTestCase {

    func testRawValuesAreLowercase() {
        XCTAssertEqual(AgentDetectedState.idle.rawValue, "idle")
        XCTAssertEqual(AgentDetectedState.working.rawValue, "working")
        XCTAssertEqual(AgentDetectedState.blocked.rawValue, "blocked")
        XCTAssertEqual(AgentDetectedState.unknown.rawValue, "unknown")
    }

    func testDecodesKnownValues() throws {
        let decoder = JSONDecoder()
        for (raw, expected): (String, AgentDetectedState) in [
            ("idle", .idle), ("working", .working), ("blocked", .blocked), ("unknown", .unknown)
        ] {
            let decoded = try decoder.decode(AgentDetectedState.self, from: Data("\"\(raw)\"".utf8))
            XCTAssertEqual(decoded, expected)
        }
    }

    func testUnknownRawValueDecodesToUnknown() throws {
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AgentDetectedState.self, from: Data("\"waiting_forever\"".utf8))
        XCTAssertEqual(decoded, .unknown, "Forward-compat: an unrecognized state from a newer server maps to .unknown")
    }

    func testEncodesCanonicalRawValue() throws {
        let data = try JSONEncoder().encode(AgentDetectedState.blocked)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"blocked\"")
    }

    func testNeedsAttentionOnlyForBlocked() {
        XCTAssertTrue(AgentDetectedState.blocked.needsAttention)
        XCTAssertFalse(AgentDetectedState.idle.needsAttention)
        XCTAssertFalse(AgentDetectedState.working.needsAttention)
        XCTAssertFalse(AgentDetectedState.unknown.needsAttention)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AgentDetectedStateTests`
Expected: FAIL — compile error "cannot find 'AgentDetectedState' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/ClaudeRelayKit/Models/AgentDetectedState.swift`:

```swift
/// Fine-grained coding-agent state detected by parsing the session's terminal
/// screen (Phase 2) — distinct from `ActivityState`, which only tracks whether
/// output is flowing. Mirrors herdr's `AgentState`.
///
/// Wire raw values are lowercase and stable. The decoder is deliberately
/// tolerant: an unrecognized value from a newer server decodes to `.unknown`
/// rather than throwing, so an older client never fails to parse a
/// `session_activity` message. This mirrors `ActivityState.init(from:)`.
public enum AgentDetectedState: String, Equatable, Sendable {
    /// Agent is running and waiting for user input (herdr "idle"/"done").
    case idle
    /// Agent is actively producing output / thinking.
    case working
    /// Agent is asking the user a question / permission prompt — needs attention.
    case blocked
    /// State could not be determined (no agent, or an ambiguous screen).
    case unknown

    /// Whether this state should raise a "needs attention" affordance in the UI.
    /// Only `.blocked` demands the user act; `.idle` merely means "done, no rush".
    public var needsAttention: Bool {
        self == .blocked
    }
}

extension AgentDetectedState: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentDetectedState(rawValue: raw) ?? .unknown
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AgentDetectedStateTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayKit/Models/AgentDetectedState.swift Tests/ClaudeRelayKitTests/AgentDetectedStateTests.swift
git commit -m "feat(kit): add AgentDetectedState wire enum with tolerant decoder

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Widen `ServerMessage.sessionActivity` with `agentState` + `title`

**Files:**
- Modify: `Sources/ClaudeRelayKit/Protocol/ServerMessage.swift`
- Modify: `Tests/ClaudeRelayKitTests/ServerMessageTests.swift:265` (pattern-match site) + new tests
- Modify: `Tests/ClaudeRelayKitTests/MessageEnvelopeTests.swift:39` (pattern-match site)

**Interfaces:**
- Consumes: `AgentDetectedState` (Task 1).
- Produces: `case sessionActivity(sessionId: UUID, activity: ActivityState, agent: String? = nil, agentState: AgentDetectedState? = nil, title: String? = nil)`. All new fields optional + defaulted, so existing constructions keep compiling; pattern-match sites must bind all five.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ClaudeRelayKitTests/ServerMessageTests.swift` inside the `// MARK: - sessionActivity` section (after `testSessionActivityRoundTrip`):

```swift
    func testSessionActivityEncodesAgentStateAndTitle() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionActivity(
            sessionId: id, activity: .agentIdle, agent: "claude",
            agentState: .blocked, title: "✳ my-project"
        )
        let data = try encoder.encode(MessageEnvelope.server(msg))
        let obj = try jsonObject(data)
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["agentState"] as? String, "blocked")
        XCTAssertEqual(payload?["title"] as? String, "✳ my-project")
    }

    func testSessionActivityOmitsNilAgentStateAndTitle() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let msg = ServerMessage.sessionActivity(sessionId: id, activity: .active)
        let data = try encoder.encode(MessageEnvelope.server(msg))
        let payload = try jsonObject(data)["payload"] as? [String: Any]
        XCTAssertNil(payload?["agentState"], "nil agentState must not appear on the wire")
        XCTAssertNil(payload?["title"], "nil title must not appear on the wire")
    }

    func testSessionActivityDecodesAgentStateAndTitle() throws {
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"session_activity","payload":{"sessionId":"\#(id)","activity":"agent_active","agent":"codex","agentState":"working","title":"⠋ build"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionActivity(_, let activity, let agent, let agentState, let title)) = envelope else {
            XCTFail("Expected sessionActivity"); return
        }
        XCTAssertEqual(activity, .agentActive)
        XCTAssertEqual(agent, "codex")
        XCTAssertEqual(agentState, .working)
        XCTAssertEqual(title, "⠋ build")
    }

    func testSessionActivityDecodesWithoutNewFields() throws {
        // An old server that never sends agentState/title must still decode.
        let id = "12345678-1234-1234-1234-123456789ABC"
        let json = #"{"type":"session_activity","payload":{"sessionId":"\#(id)","activity":"idle"}}"#
        let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.sessionActivity(_, let activity, _, let agentState, let title)) = envelope else {
            XCTFail("Expected sessionActivity"); return
        }
        XCTAssertEqual(activity, .idle)
        XCTAssertNil(agentState)
        XCTAssertNil(title)
    }
```

Update the existing pattern-match at `ServerMessageTests.swift:265` (in `testSessionActivityFieldVerification`) from:

```swift
        guard case .server(.sessionActivity(let sessionId, let activity, let agent)) = envelope else {
```
to:
```swift
        guard case .server(.sessionActivity(let sessionId, let activity, let agent, _, _)) = envelope else {
```

Update the pattern-match at `MessageEnvelopeTests.swift:39` (in `testSessionActivityLegacyDecodes`) from:

```swift
        guard case .server(.sessionActivity(_, let activity, let agent)) = envelope else {
```
to:
```swift
        guard case .server(.sessionActivity(_, let activity, let agent, _, _)) = envelope else {
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ServerMessageTests`
Expected: FAIL — compile errors on the new `agentState:`/`title:` argument labels (case doesn't accept them yet).

- [ ] **Step 3: Widen the enum case, coding keys, encode, and decode**

In `Sources/ClaudeRelayKit/Protocol/ServerMessage.swift`:

Change the case declaration (line 15) from:
```swift
    case sessionActivity(sessionId: UUID, activity: ActivityState, agent: String? = nil)
```
to:
```swift
    case sessionActivity(
        sessionId: UUID, activity: ActivityState, agent: String? = nil,
        agentState: AgentDetectedState? = nil, title: String? = nil
    )
```

Add the two keys to `PayloadCodingKeys` (line 66-68) — append `agentState, title`:
```swift
    private enum PayloadCodingKeys: String, CodingKey {
        case reason, sessionId, cols, rows, state, code, message, sessions, activity, agent, name, success, protocolVersion
        case agentState, title
    }
```

Replace the encode arm (lines 98-101):
```swift
        case .sessionActivity(let sessionId, let activity, let agent, let agentState, let title):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(activity, forKey: .activity)
            try container.encodeIfPresent(agent, forKey: .agent)
            try container.encodeIfPresent(agentState, forKey: .agentState)
            try container.encodeIfPresent(title, forKey: .title)
```

Replace the decode arm (lines 161-165):
```swift
        case "session_activity":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let activity = try container.decode(ActivityState.self, forKey: .activity)
            let agent = try container.decodeIfPresent(String.self, forKey: .agent)
            let agentState = try container.decodeIfPresent(AgentDetectedState.self, forKey: .agentState)
            let title = try container.decodeIfPresent(String.self, forKey: .title)
            return .sessionActivity(sessionId: sessionId, activity: activity, agent: agent,
                                    agentState: agentState, title: title)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ServerMessageTests && swift test --filter MessageEnvelopeTests`
Expected: PASS (all existing + 4 new sessionActivity tests). The round-trip test at `ServerMessageTests.swift:189` still passes because Equatable now compares the two new (nil) fields too.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayKit/Protocol/ServerMessage.swift Tests/ClaudeRelayKitTests/ServerMessageTests.swift Tests/ClaudeRelayKitTests/MessageEnvelopeTests.swift
git commit -m "feat(protocol): carry agentState + title on session_activity (optional, back-compat)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Add optional `agentState` / `title` to `SessionInfo`

**Files:**
- Modify: `Sources/ClaudeRelayKit/Models/SessionInfo.swift`
- Test: `Tests/ClaudeRelayKitTests/SessionInfoTests.swift` (create if absent; otherwise append)

**Interfaces:**
- Consumes: `AgentDetectedState` (Task 1).
- Produces: two new stored `let`s `agentState: AgentDetectedState?` and `title: String?`; init gains defaulted params; `enriched(...)` becomes `enriched(activity:agent:agentState:title:)`. `transitioning(to:)`, `with(name:)`, `with(tokenId:)` preserve the new fields.

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelayKitTests/SessionInfoTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayKit

final class SessionInfoTests: XCTestCase {

    private func base() -> SessionInfo {
        SessionInfo(id: UUID(), name: "s", state: .activeAttached, tokenId: "t",
                    createdAt: Date(), cols: 80, rows: 24)
    }

    func testDefaultsAreNil() {
        let info = base()
        XCTAssertNil(info.agentState)
        XCTAssertNil(info.title)
    }

    func testEnrichedCarriesAgentStateAndTitle() {
        let info = base().enriched(activity: .agentIdle, agent: "claude",
                                   agentState: .blocked, title: "✳ proj")
        XCTAssertEqual(info.activity, .agentIdle)
        XCTAssertEqual(info.agent, "claude")
        XCTAssertEqual(info.agentState, .blocked)
        XCTAssertEqual(info.title, "✳ proj")
    }

    func testCopyHelpersPreserveAgentStateAndTitle() {
        let info = SessionInfo(id: UUID(), name: "s", state: .activeAttached, tokenId: "t",
                               createdAt: Date(), cols: 80, rows: 24,
                               activity: .agentActive, agent: "codex",
                               agentState: .working, title: "⠙ x")
        XCTAssertEqual(info.transitioning(to: .activeDetached).agentState, .working)
        XCTAssertEqual(info.transitioning(to: .activeDetached).title, "⠙ x")
        XCTAssertEqual(info.with(name: "renamed").agentState, .working)
        XCTAssertEqual(info.with(tokenId: "t2").title, "⠙ x")
    }

    func testCodableRoundTripWithNewFields() throws {
        let info = base().enriched(activity: .agentIdle, agent: "claude",
                                   agentState: .idle, title: "t")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(SessionInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionInfoTests`
Expected: FAIL — compile error: `enriched` has no `agentState:`/`title:` params and no such properties exist.

- [ ] **Step 3: Add the fields and thread them through init + all copy helpers**

Replace `Sources/ClaudeRelayKit/Models/SessionInfo.swift` entirely with:

```swift
import Foundation

/// Contains metadata about a ClaudeRelay session.
public struct SessionInfo: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let state: SessionState
    public let tokenId: String
    public let createdAt: Date
    public let cols: UInt16
    public let rows: UInt16
    public let activity: ActivityState?
    /// The coding agent currently running in this session, if any.
    /// Nil when no agent is running or when the server predates multi-agent support.
    public let agent: String?
    /// Fine-grained agent state detected from the terminal screen (Phase 2).
    /// Nil when no agent is running or when the server predates screen detection.
    public let agentState: AgentDetectedState?
    /// The session's current window title (OSC 0/2), if any. Surfaced in the sidebar.
    public let title: String?

    public init(
        id: UUID,
        name: String? = nil,
        state: SessionState,
        tokenId: String,
        createdAt: Date,
        cols: UInt16,
        rows: UInt16,
        activity: ActivityState? = nil,
        agent: String? = nil,
        agentState: AgentDetectedState? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.tokenId = tokenId
        self.createdAt = createdAt
        self.cols = cols
        self.rows = rows
        self.activity = activity
        self.agent = agent
        self.agentState = agentState
        self.title = title
    }

    // MARK: - Copy Helpers

    // Immutable-update helpers — produce a new SessionInfo with targeted field changes.
    public func transitioning(to newState: SessionState) -> SessionInfo {
        SessionInfo(id: id, name: name, state: newState, tokenId: tokenId,
                    createdAt: createdAt, cols: cols, rows: rows,
                    activity: activity, agent: agent, agentState: agentState, title: title)
    }

    public func with(name newName: String?) -> SessionInfo {
        SessionInfo(id: id, name: newName, state: state, tokenId: tokenId,
                    createdAt: createdAt, cols: cols, rows: rows,
                    activity: activity, agent: agent, agentState: agentState, title: title)
    }

    public func with(tokenId newTokenId: String) -> SessionInfo {
        SessionInfo(id: id, name: name, state: state, tokenId: newTokenId,
                    createdAt: createdAt, cols: cols, rows: rows,
                    activity: activity, agent: agent, agentState: agentState, title: title)
    }

    public func enriched(
        activity: ActivityState?,
        agent: String?,
        agentState: AgentDetectedState? = nil,
        title: String? = nil
    ) -> SessionInfo {
        SessionInfo(id: id, name: name, state: state, tokenId: tokenId,
                    createdAt: createdAt, cols: cols, rows: rows,
                    activity: activity, agent: agent, agentState: agentState, title: title)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionInfoTests`
Expected: PASS (4 tests). `Codable` synthesis picks up the two new optional properties automatically; old JSON without them decodes to nil.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayKit/Models/SessionInfo.swift Tests/ClaudeRelayKitTests/SessionInfoTests.swift
git commit -m "feat(kit): SessionInfo carries optional agentState + title

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: Thread `agentState` + `title` through the server observer chain

**Files:**
- Modify: `Sources/ClaudeRelayServer/Actors/SessionActivityMonitor.swift`
- Modify: `Sources/ClaudeRelayServer/Actors/PTYSession.swift`
- Modify: `Sources/ClaudeRelayServer/Actors/SessionManager.swift`
- Modify: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`
- Modify: `Sources/ClaudeRelayServer/Network/SessionRequestHandlers.swift`
- Modify: `Tests/ClaudeRelayServerTests/SessionManagerTestCase.swift` (MockPTYSession)
- Modify: `Tests/ClaudeRelayServerTests/SessionObserverTests.swift` (observer closures + assertions)
- Modify: `Tests/ClaudeRelayServerTests/SessionActivityMonitorTests.swift` (helper wrappers)

**Interfaces:**
- Consumes: `AgentDetectedState` (Task 1), widened `ServerMessage.sessionActivity` (Task 2), `SessionInfo.enriched(...agentState:title:)` (Task 3).
- Produces:
  - `SessionActivityMonitor`: `onChange: @Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void`; new `public private(set) var agentState: AgentDetectedState?` and `public private(set) var title: String?` (both nil in Phase 1); `transition(to:)` passes them.
  - `PTYSessionProtocol`: `setActivityHandler(_ handler: @escaping @Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void)`; `getAgentState() -> AgentDetectedState?`; `getTitle() -> String?`.
  - `SessionManager.ActivityObserver = @Sendable (UUID, ActivityState, String?, AgentDetectedState?, String?) -> Void`; `reportActivityChange(sessionId:activity:agent:agentState:title:revision:)`; `ManagedSession` gains `latestAgentState` / `latestTitle`.
  - `SessionRequestHandlers`: `struct ActivitySnapshot { let activity: ActivityState; let agent: CodingAgent?; let agentState: AgentDetectedState?; let title: String? }` used to shrink the attach/resume work-closure tuples (removes the existing `large_tuple` warning at line 73).

> **Why one task:** the callback type flows monitor → PTY protocol → SessionManager → handler in one unbroken chain. Splitting it leaves the tree uncompilable between commits. All source + all three server test files are updated together.

- [ ] **Step 1: Update the monitor's `onChange` signature and add nil getters (source)**

In `Sources/ClaudeRelayServer/Actors/SessionActivityMonitor.swift`:

Add two stored properties after `activeAgent` (after line 23):
```swift
    /// Fine-grained agent state from screen detection (Phase 2). Nil in Phase 1
    /// — the arbiter that populates it is added in a later task.
    public private(set) var agentState: AgentDetectedState?

    /// Latest window title (OSC 0/2) observed for this session, if any.
    public private(set) var title: String?
```

Change the `onChange` property type (line 34):
```swift
    private let onChange: @Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void
```

Change the `init` parameter (line 67):
```swift
        onChange: @escaping @Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void
```

Change the `transition(to:)` emit (line 275):
```swift
        onChange(newState, activeAgent, agentState, title, revision)
```

- [ ] **Step 2: Update `PTYSession` — protocol, box, init closure, getters, setter (source)**

In `Sources/ClaudeRelayServer/Actors/PTYSession.swift`:

Protocol (lines 25-30) — add getters and widen the setter:
```swift
    func getActivityState() -> ActivityState
    func getActiveAgent() -> CodingAgent?
    func getAgentState() -> AgentDetectedState?
    func getTitle() -> String?
    /// Activity updates carry a monotonic `revision`. Downstream observers
    /// that cross isolation boundaries drop updates whose revision is older
    /// than what they last recorded — see `SessionManager.reportActivityChange`.
    func setActivityHandler(
        _ handler: @escaping @Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void
    )
```

`ActivityCallbackBox` (line 49):
```swift
    var handler: (@Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void)?
```

Stored `activityHandler` (line 80):
```swift
    private var activityHandler: (@Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void)?
```

Monitor construction closure in `init` (lines 193-195):
```swift
            onChange: { newState, agent, agentState, title, revision in
                box.handler?(newState, agent, agentState, title, revision)
            }
```

Add getters next to the existing ones (after line 376):
```swift
    /// Returns the fine-grained agent state detected from the screen, if any.
    public func getAgentState() -> AgentDetectedState? {
        activityMonitor.agentState
    }

    /// Returns the current window title (OSC 0/2), if any.
    public func getTitle() -> String? {
        activityMonitor.title
    }
```

Widen `setActivityHandler` (lines 381-384):
```swift
    public func setActivityHandler(
        _ handler: @escaping @Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void
    ) {
        self.activityHandler = handler
        self.activityCallbackBox.handler = handler
    }
```

- [ ] **Step 3: Update `SessionManager` — typealias, cache, report, list, observer replay (source)**

In `Sources/ClaudeRelayServer/Actors/SessionManager.swift`:

Typealias (line 23):
```swift
    public typealias ActivityObserver =
        @Sendable (UUID, ActivityState, String?, AgentDetectedState?, String?) -> Void
```

`ManagedSession` — add two fields after `latestAgent` (after line 39):
```swift
        /// Latest fine-grained agent state (Phase 2 screen detection).
        var latestAgentState: AgentDetectedState?
        /// Latest window title (OSC 0/2).
        var latestTitle: String?
```

`setActivityHandler` registration in `createSession` (lines 105-112):
```swift
        await pty.setActivityHandler { [weak self] newState, agent, agentState, title, revision in
            Task {
                await self?.reportActivityChange(
                    sessionId: sessionId, activity: newState, agent: agent?.id,
                    agentState: agentState, title: title, revision: revision
                )
            }
        }
```

`listSessionsForToken` (line 351) and `listAllSessions` (line 357) — widen `enriched`:
```swift
            .map { $0.info.enriched(activity: $0.latestActivity, agent: $0.latestAgent,
                                    agentState: $0.latestAgentState, title: $0.latestTitle) }
```
(apply the same `.enriched(...)` change to both call sites)

`addActivityObserver` replay (line 373):
```swift
            callback(managed.info.id, managed.latestActivity, managed.latestAgent,
                     managed.latestAgentState, managed.latestTitle)
```

`reportActivityChange` (lines 390-410) — widen signature, cache, and fan-out:
```swift
    public func reportActivityChange(
        sessionId: UUID,
        activity: ActivityState,
        agent: String? = nil,
        agentState: AgentDetectedState? = nil,
        title: String? = nil,
        revision: UInt64 = .max
    ) {
        guard var managed = sessions[sessionId] else { return }
        guard !managed.info.state.isTerminal else { return }
        if revision < managed.activityRevision { return }
        managed.activityRevision = revision
        managed.latestActivity = activity
        managed.latestAgent = agent
        managed.latestAgentState = agentState
        managed.latestTitle = title
        sessions[sessionId] = managed
        let tokenId = managed.info.tokenId
        for (_, callback) in activityObservers.forToken(tokenId) {
            callback(sessionId, activity, agent, agentState, title)
        }
    }
```

- [ ] **Step 4: Update `RelayMessageHandler` observer closure (source)**

In `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`, replace the observer registration (lines 279-286):
```swift
                let activityId = await manager.addActivityObserver(tokenId: info.id) {
                    [weak self] sessionId, activity, agent, agentState, title in
                    observerCtx.value.eventLoop.execute {
                        self?.sendServerMessage(
                            .sessionActivity(sessionId: sessionId, activity: activity, agent: agent,
                                             agentState: agentState, title: title),
                            context: observerCtx.value
                        )
                    }
                }
```

- [ ] **Step 5: Add `ActivitySnapshot` and rework attach/resume in `SessionRequestHandlers` (source)**

In `Sources/ClaudeRelayServer/Network/SessionRequestHandlers.swift`:

Add the struct just inside the `extension RelayMessageHandler {` opening (after line 17):
```swift
    /// Bundles the activity fields read off a PTY at attach/resume time.
    /// Returning a struct instead of a wide tuple keeps the work-closure
    /// return type under SwiftLint's `large_tuple` threshold.
    struct ActivitySnapshot {
        let activity: ActivityState
        let agent: CodingAgent?
        let agentState: AgentDetectedState?
        let title: String?
    }
```

Rework `handleSessionAttach` work + onSuccess (lines 71-98):
```swift
        bridgeToEventLoopWithCtx(
            context: context,
            work: { [weak self] ctx -> (SessionInfo, any PTYSessionProtocol, Data, ActivitySnapshot) in
                await self?.autoDetachIfNeeded(ctx: ctx)
                let (info, pty) = try await mgr.attachSession(id: sessionId, tokenId: tokenId, excludeObserver: myStealId)
                let buffered = await pty.readBuffer()
                let filtered = RelayMessageHandler.filterEscapeResponses(buffered)
                let snapshot = ActivitySnapshot(
                    activity: await pty.getActivityState(),
                    agent: await pty.getActiveAgent(),
                    agentState: await pty.getAgentState(),
                    title: await pty.getTitle()
                )
                RelayLogger.log(category: "session", "Session attached: \(sessionId)")
                return (info, pty, filtered, snapshot)
            },
            onSuccess: { handler, ctx, tuple in
                let (info, pty, filtered, snapshot) = tuple
                handler.attachedSessionId = sessionId
                handler.attachedPTY = pty
                handler.sendServerMessage(.sessionAttached(sessionId: sessionId, state: info.state.rawValue), context: ctx)
                if !filtered.isEmpty {
                    handler.sendChunkedBinaryData(filtered, context: ctx)
                }
                handler.sendServerMessage(.replayComplete(sessionId: sessionId), context: ctx)
                handler.sendServerMessage(
                    .sessionActivity(sessionId: sessionId, activity: snapshot.activity, agent: snapshot.agent?.id,
                                     agentState: snapshot.agentState, title: snapshot.title),
                    context: ctx
                )
                handler.wirePTYOutput(pty: pty, context: ctx, repaintAfter: true)
            },
```
(leave `onFailure` unchanged.)

Rework `handleSessionResume` work + onSuccess (lines 112-141):
```swift
        bridgeToEventLoopWithCtx(
            context: context,
            work: { [weak self] ctx -> (any PTYSessionProtocol, Data, ActivitySnapshot) in
                await self?.autoDetachIfNeeded(ctx: ctx)
                let (_, _, pty) = try await mgr.resumeSession(id: sessionId, tokenId: tokenId, excludeObserver: myStealId)
                RelayLogger.log(category: "session", "Session resumed: \(sessionId) (skipReplay=\(skipReplay))")
                let buffered = skipReplay ? Data() : await pty.readBuffer()
                let stripped = RelayMessageHandler.filterEscapeResponses(buffered)
                let filtered = ScrollbackSanitizer.sanitize(stripped)
                let snapshot = ActivitySnapshot(
                    activity: await pty.getActivityState(),
                    agent: await pty.getActiveAgent(),
                    agentState: await pty.getAgentState(),
                    title: await pty.getTitle()
                )
                return (pty, filtered, snapshot)
            },
            onSuccess: { handler, ctx, tuple in
                let (pty, filtered, snapshot) = tuple
                handler.attachedSessionId = sessionId
                handler.attachedPTY = pty
                handler.sendServerMessage(.sessionResumed(sessionId: sessionId), context: ctx)
                if !filtered.isEmpty {
                    handler.sendChunkedBinaryData(filtered, context: ctx)
                }
                handler.sendServerMessage(.replayComplete(sessionId: sessionId), context: ctx)
                handler.sendServerMessage(
                    .sessionActivity(sessionId: sessionId, activity: snapshot.activity, agent: snapshot.agent?.id,
                                     agentState: snapshot.agentState, title: snapshot.title),
                    context: ctx
                )
                handler.wirePTYOutput(pty: pty, context: ctx, repaintAfter: true)
            },
```
(leave `onFailure` unchanged.)

- [ ] **Step 6: Update the three server test files (tests)**

In `Tests/ClaudeRelayServerTests/SessionManagerTestCase.swift` (MockPTYSession):

Widen the stored handler (line 13):
```swift
    private var activityHandler: (@Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void)?
```
Add getters after `getActiveAgent()` (after line 42):
```swift
    func getAgentState() -> AgentDetectedState? { nil }
    func getTitle() -> String? { nil }
```
Widen the setter (lines 43-45):
```swift
    func setActivityHandler(
        _ handler: @escaping @Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void
    ) {
        activityHandler = handler
    }
```

In `Tests/ClaudeRelayServerTests/SessionObserverTests.swift`:

Update every `addActivityObserver` closure to the 5-param shape. Line 21:
```swift
        let observerId = await manager.addActivityObserver(tokenId: tokenInfo.id) { sessionId, activity, agent, _, _ in
```
Line 47:
```swift
        let observerId = await manager.addActivityObserver(tokenId: tokenA.id) { sessionId, _, _, _, _ in
```
Line 68:
```swift
        let observerId = await manager.addActivityObserver(tokenId: tokenInfo.id) { _, _, _, _, _ in
```
Line 251:
```swift
        _ = await manager.addActivityObserver(tokenId: tokenInfo.id) { _, _, _, _, _ in }
```
The `reportActivityChange` calls at lines 28, 52, 53, 73, 76, 221-222, 228-229, 237-238 keep compiling unchanged (new params are defaulted). The assertions at 223-242 that read `.activity` / `.agent` remain valid.

In `Tests/ClaudeRelayServerTests/SessionActivityMonitorTests.swift`, update the three helper wrappers so their inner `SessionActivityMonitor(...)` closures take 5 params:

`makeMonitor` (line 18):
```swift
            onChange: { state, agent, _, _, _ in onChange(state, agent) }
```
`makeMonitorWithRevision` (lines 23-33) — widen its own `onChange` param and pass through:
```swift
    private func makeMonitorWithRevision(
        silenceThreshold: TimeInterval = 0.1,
        agentSilenceThreshold: TimeInterval = 0.2,
        onChange: @escaping @Sendable (ActivityState, CodingAgent?, UInt64) -> Void
    ) -> SessionActivityMonitor {
        SessionActivityMonitor(
            silenceThreshold: silenceThreshold,
            agentSilenceThreshold: agentSilenceThreshold,
            onChange: { state, agent, _, _, revision in onChange(state, agent, revision) }
        )
    }
```
`makeMonitorStateOnly` is unchanged (it delegates to `makeMonitor`).

- [ ] **Step 7: Build + run the server + kit suites**

Run: `swift build`
Expected: builds with no errors. (The `large_tuple` warning previously at `SessionRequestHandlers.swift:73` is now gone — attach returns a 4-member tuple whose widest member is a struct.)

Run: `swift test --filter SessionObserverTests && swift test --filter SessionActivityMonitorTests`
Expected: PASS. `testActivityObserverReceivesChanges` still asserts `received == [.active, .agentActive]` and `receivedAgents == [nil, "claude"]` — unaffected by the two ignored new params.

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeRelayServer Tests/ClaudeRelayServerTests
git commit -m "feat(server): thread agentState + title through activity observer chain

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Thread `agentState` + `title` through the client + add seen-tracking

**Files:**
- Modify: `Sources/ClaudeRelayClient/RelayConnection.swift`
- Modify: `Sources/ClaudeRelayClient/ViewModels/ActivityCoordinator.swift`
- Modify: `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`
- Test: `Tests/ClaudeRelayClientTests/ActivityCoordinatorTests.swift` (create)

**Interfaces:**
- Consumes: widened `ServerMessage.sessionActivity` (Task 2), `SessionInfo.agentState`/`.title` (Task 3), `AgentDetectedState` (Task 1).
- Produces:
  - `RelayConnection.onSessionActivity: ((UUID, ActivityState, String?, AgentDetectedState?, String?) -> Void)?`
  - `ActivityCoordinator`: `@Published agentStates: [UUID: AgentDetectedState]`, `@Published sessionTitles: [UUID: String]`, `@Published unseenSessions: Set<UUID>`; `func markSeen(_ id: UUID)`; widened `handleActivityUpdate(sessionId:activity:agent:agentState:title:onAgentActiveChange:)`; `agentState(for:) -> AgentDetectedState?`; `title(for:) -> String?`.
  - `SharedSessionCoordinator`: read-through `agentState(for:)`, `title(for:)`; `markSeen` at active-session slots.

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelayClientTests/ActivityCoordinatorTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

@MainActor
final class ActivityCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> ActivityCoordinator {
        let defaults = UserDefaults(suiteName: "ActivityCoordinatorTests-\(UUID().uuidString)")!
        let store = SessionOwnershipStore(keyPrefix: "test", deviceId: "dev", defaults: defaults)
        return ActivityCoordinator(ownershipStore: store, initialAgents: [:])
    }

    func testHandleActivityUpdateStoresAgentStateAndTitle() {
        let coord = makeCoordinator()
        let id = UUID()
        coord.handleActivityUpdate(sessionId: id, activity: .agentActive, agent: "claude",
                                   agentState: .working, title: "⠋ build")
        XCTAssertEqual(coord.agentState(for: id), .working)
        XCTAssertEqual(coord.title(for: id), "⠋ build")
    }

    func testBlockedStateMarksSessionUnseen() {
        let coord = makeCoordinator()
        let id = UUID()
        coord.handleActivityUpdate(sessionId: id, activity: .agentIdle, agent: "claude",
                                   agentState: .blocked, title: nil)
        XCTAssertTrue(coord.unseenSessions.contains(id), "A blocked agent should mark the session unseen")
    }

    func testDoneStateMarksSessionUnseen() {
        let coord = makeCoordinator()
        let id = UUID()
        // Agent goes idle after working: herdr's "done" — worth surfacing until seen.
        coord.handleActivityUpdate(sessionId: id, activity: .agentIdle, agent: "claude",
                                   agentState: .idle, title: nil)
        XCTAssertTrue(coord.unseenSessions.contains(id))
    }

    func testWorkingStateDoesNotMarkUnseen() {
        let coord = makeCoordinator()
        let id = UUID()
        coord.handleActivityUpdate(sessionId: id, activity: .agentActive, agent: "claude",
                                   agentState: .working, title: nil)
        XCTAssertFalse(coord.unseenSessions.contains(id))
    }

    func testMarkSeenClearsUnseen() {
        let coord = makeCoordinator()
        let id = UUID()
        coord.handleActivityUpdate(sessionId: id, activity: .agentIdle, agent: "claude",
                                   agentState: .blocked, title: nil)
        coord.markSeen(id)
        XCTAssertFalse(coord.unseenSessions.contains(id))
    }

    func testForgetSessionClearsAllNewMaps() {
        let coord = makeCoordinator()
        let id = UUID()
        coord.handleActivityUpdate(sessionId: id, activity: .agentIdle, agent: "claude",
                                   agentState: .blocked, title: "t")
        coord.forgetSession(id)
        XCTAssertNil(coord.agentState(for: id))
        XCTAssertNil(coord.title(for: id))
        XCTAssertFalse(coord.unseenSessions.contains(id))
    }

    func testAgentExitClearsAgentStateAndTitle() {
        let coord = makeCoordinator()
        let id = UUID()
        coord.handleActivityUpdate(sessionId: id, activity: .agentActive, agent: "claude",
                                   agentState: .working, title: "t")
        // Agent exits: activity becomes .idle with no agent — clear derived state.
        coord.handleActivityUpdate(sessionId: id, activity: .idle, agent: nil,
                                   agentState: nil, title: nil)
        XCTAssertNil(coord.agentState(for: id))
        XCTAssertNil(coord.title(for: id))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ActivityCoordinatorTests`
Expected: FAIL — `handleActivityUpdate` has no `agentState:`/`title:` params; `agentState(for:)`, `title(for:)`, `markSeen`, `unseenSessions` don't exist.

- [ ] **Step 3: Extend `ActivityCoordinator`**

In `Sources/ClaudeRelayClient/ViewModels/ActivityCoordinator.swift`:

Add published state after `sessionsAwaitingInput` (after line 34):
```swift
    /// Fine-grained agent state per session (Phase 2 screen detection).
    /// Nil-absent when the server doesn't report it (older server / no agent).
    @Published public var agentStates: [UUID: AgentDetectedState] = [:]

    /// Latest window title per session, surfaced under the session name.
    @Published public var sessionTitles: [UUID: String] = [:]

    /// Sessions with an unacknowledged blocked/done state — drives the
    /// "needs attention" affordance. Cleared by `markSeen` when the user
    /// activates the session. Mirrors herdr's client-side `seen` bit.
    @Published public var unseenSessions: Set<UUID> = []
```

Add read accessors after `activityState(for:)` (after line 83):
```swift
    /// The fine-grained agent state for a session, or nil.
    public func agentState(for sessionId: UUID) -> AgentDetectedState? {
        agentStates[sessionId]
    }

    /// The window title for a session, or nil.
    public func title(for sessionId: UUID) -> String? {
        sessionTitles[sessionId]
    }

    /// Mark a session's state as seen — clears its "needs attention" flag.
    /// Called by the coordinator when the session becomes active.
    public func markSeen(_ sessionId: UUID) {
        unseenSessions.remove(sessionId)
    }
```

Replace `handleActivityUpdate` (lines 94-121) with the widened version:
```swift
    public func handleActivityUpdate(
        sessionId: UUID,
        activity: ActivityState,
        agent: String?,
        agentState: AgentDetectedState? = nil,
        title: String? = nil,
        onAgentActiveChange: (UUID, Bool) -> Void = { _, _ in }
    ) {
        // Only persist to UserDefaults on actual state transitions, not redundant updates
        var changed = false
        if activity.isAgentRunning, let agentId = agent {
            if agentSessions[sessionId] != agentId {
                agentSessions[sessionId] = agentId
                onAgentActiveChange(sessionId, true)
                changed = true
            }
        } else {
            if agentSessions.removeValue(forKey: sessionId) != nil {
                onAgentActiveChange(sessionId, false)
                changed = true
            }
        }
        if changed { ownershipStore.saveAgents(agentSessions) }

        // Fine-grained state + title mirror the agent-running lifecycle: when no
        // agent runs, clear them so a stale "blocked" never lingers.
        if agent != nil {
            if let agentState { agentStates[sessionId] = agentState } else { agentStates.removeValue(forKey: sessionId) }
            if let title, !title.isEmpty { sessionTitles[sessionId] = title } else { sessionTitles.removeValue(forKey: sessionId) }
        } else {
            agentStates.removeValue(forKey: sessionId)
            sessionTitles.removeValue(forKey: sessionId)
        }

        // "Needs attention" bucket: a blocked prompt or a just-finished (idle-
        // after-working "done") agent is worth surfacing until the user looks.
        // Working is in-progress — not attention-worthy on its own.
        if agent != nil, let agentState, agentState == .blocked || agentState == .idle {
            unseenSessions.insert(sessionId)
        } else if agentState == .working || agent == nil {
            unseenSessions.remove(sessionId)
        }

        if activity == .agentIdle, agentSessions[sessionId] != nil {
            sessionsAwaitingInput.insert(sessionId)
        } else {
            sessionsAwaitingInput.remove(sessionId)
        }
    }
```

Extend `forgetSession` (lines 137-140):
```swift
    public func forgetSession(_ sessionId: UUID) {
        agentSessions.removeValue(forKey: sessionId)
        sessionsAwaitingInput.remove(sessionId)
        agentStates.removeValue(forKey: sessionId)
        sessionTitles.removeValue(forKey: sessionId)
        unseenSessions.remove(sessionId)
    }
```

Extend `applyPrunedAgents` (lines 145-149):
```swift
    public func applyPrunedAgents(_ removedAgents: Set<UUID>) {
        if !removedAgents.isEmpty {
            sessionsAwaitingInput.subtract(removedAgents)
            unseenSessions.subtract(removedAgents)
            for id in removedAgents {
                agentStates.removeValue(forKey: id)
                sessionTitles.removeValue(forKey: id)
            }
        }
    }
```

- [ ] **Step 4: Widen `RelayConnection.onSessionActivity` + its dispatch**

In `Sources/ClaudeRelayClient/RelayConnection.swift`:

Property (line 99):
```swift
    public var onSessionActivity: ((UUID, ActivityState, String?, AgentDetectedState?, String?) -> Void)?
```

Dispatch case (lines 487-488):
```swift
                    case .sessionActivity(let sessionId, let activity, let agent, let agentState, let title):
                        onSessionActivity?(sessionId, activity, agent, agentState, title)
```
(`RelayConnectionTests.swift:28`'s `XCTAssertNil(connection.onSessionActivity)` still compiles — only the property's function type changed.)

- [ ] **Step 5: Thread through `SharedSessionCoordinator`**

In `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`:

Connection wiring (lines 227-231):
```swift
        connection.onSessionActivity = { [weak self] sessionId, activity, agent, agentState, title in
            Task { @MainActor [weak self] in
                self?.handleActivityUpdate(sessionId: sessionId, activity: activity, agent: agent,
                                           agentState: agentState, title: title)
            }
        }
```

`fetchSessions` per-session threading (lines 338-341):
```swift
            for session in sessions {
                let activity = session.activity ?? .idle
                handleActivityUpdate(sessionId: session.id, activity: activity, agent: session.agent,
                                     agentState: session.agentState, title: session.title)
            }
```

Widen the private `handleActivityUpdate` (lines 654-663):
```swift
    private func handleActivityUpdate(
        sessionId: UUID, activity: ActivityState, agent: String? = nil,
        agentState: AgentDetectedState? = nil, title: String? = nil
    ) {
        activityCoordinator.handleActivityUpdate(
            sessionId: sessionId,
            activity: activity,
            agent: agent,
            agentState: agentState,
            title: title,
            onAgentActiveChange: { [weak self] id, isActive in
                self?.terminalViewModels[id]?.isAgentActive = isActive
            }
        )
    }
```

Add read-through accessors next to `activityState(for:)` (after line 429):
```swift
    /// Fine-grained agent state for a session (Phase 2), or nil.
    public func agentState(for sessionId: UUID) -> AgentDetectedState? {
        activityCoordinator.agentState(for: sessionId)
    }

    /// Window title for a session, or nil.
    public func title(for sessionId: UUID) -> String? {
        activityCoordinator.title(for: sessionId)
    }

    /// Whether a session has an unacknowledged blocked/done state.
    public func isUnseen(_ sessionId: UUID) -> Bool {
        activityCoordinator.unseenSessions.contains(sessionId)
    }
```

Add `markSeen` calls at the three points where a session becomes active. After `activeSessionId = sessionId` in `createNewSession` (line 461):
```swift
            activeSessionId = sessionId
            activityCoordinator.markSeen(sessionId)
```
After `activeSessionId = id` in `switchToSession` (line 498):
```swift
            activeSessionId = id
            activityCoordinator.markSeen(id)
```
After `activeSessionId = id` in `attachRemoteSession` (line 551):
```swift
            activeSessionId = id
            activityCoordinator.markSeen(id)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter ActivityCoordinatorTests`
Expected: PASS (7 tests).

Run: `swift test --filter SharedSessionCoordinatorTests && swift test --filter RelayConnectionTests`
Expected: PASS — existing assertions on `agentSessions` / `sessionsAwaitingInput` are unaffected.

- [ ] **Step 7: Build to confirm both app targets still compile against the widened client**

Run: `swift build`
Expected: builds clean. (App-target sidebar views still call the unchanged `activityState(for:)` / `activeAgent(for:)`; the widened `onSessionActivity` is internal to the client library.)

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeRelayClient Tests/ClaudeRelayClientTests
git commit -m "feat(client): store agentState/title + unseen-session tracking

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

# PHASE 2 — Detection Engine & Rich UI

## Task 6: Add SwiftTerm to the server target + headless `TerminalScreenModel`

**Files:**
- Modify: `Package.swift`
- Create: `Sources/ClaudeRelayServer/Detection/TerminalScreenModel.swift`
- Test: `Tests/ClaudeRelayServerTests/TerminalScreenModelTests.swift`

**Interfaces:**
- Consumes: SwiftTerm's `Terminal`, `TerminalDelegate`, `Terminal.ProgressReport`, `Terminal.ProgressReportState`.
- Produces:
  - `struct ScreenSnapshot: Equatable { let text: String; let oscTitle: String; let oscProgress: String }`
  - `final class TerminalScreenModel { init(cols: UInt16, rows: UInt16); func feed(_ data: Data); func resize(cols: UInt16, rows: UInt16); func snapshot() -> ScreenSnapshot }`

> **SwiftTerm constraint (verified against the pinned 1.2.0 checkout):** `Terminal` holds its delegate weakly (`weak var tdel`). `TerminalScreenModel` must therefore **strongly retain** its delegate object, or title/progress callbacks stop firing. `TerminalDelegate` has default no-op implementations for `setTerminalTitle`, `progressReport`, etc.; only `send(source:data:)` is required. `Terminal.ProgressReportState.remove` has rawValue 0 — herdr's `^4;0` OSC-progress match corresponds to `.remove`.

- [ ] **Step 1: Add SwiftTerm to `Package.swift`**

Add to `dependencies` (after line 20):
```swift
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
```

Add to the `ClaudeRelayServer` target's `dependencies` array (after line 46, before the closing bracket):
```swift
                .product(name: "SwiftTerm", package: "SwiftTerm"),
```

Add a `resources:` argument to the `ClaudeRelayServer` executableTarget (after `path: "Sources/ClaudeRelayServer"` at line 48). The final target becomes:
```swift
        .executableTarget(
            name: "ClaudeRelayServer",
            dependencies: [
                "ClaudeRelayKit",
                "CPTYShim",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/ClaudeRelayServer",
            resources: [
                .copy("Resources/Agents"),
            ]
        ),
```

Create the resources directory so SPM doesn't error on the missing path:
```bash
mkdir -p Sources/ClaudeRelayServer/Resources/Agents
```
(The three JSON manifests land here in Task 8; an empty dir with a `.gitkeep` is fine for now.)
```bash
touch Sources/ClaudeRelayServer/Resources/Agents/.gitkeep
```

- [ ] **Step 2: Resolve dependencies + confirm build picks up SwiftTerm**

Run: `swift build`
Expected: SwiftTerm 1.2.x resolves and the package builds (no source uses it yet).

- [ ] **Step 3: Write the failing test**

Create `Tests/ClaudeRelayServerTests/TerminalScreenModelTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayServer

final class TerminalScreenModelTests: XCTestCase {

    func testPlainTextAppearsInSnapshot() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        model.feed(Data("hello world".utf8))
        XCTAssertTrue(model.snapshot().text.contains("hello world"))
    }

    func testTrailingBlankColumnsAreTrimmed() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        model.feed(Data("abc".utf8))
        // translateToString(trimRight:) must drop the null cells padding the row.
        let firstLine = model.snapshot().text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        XCTAssertEqual(firstLine, "abc")
    }

    func testOSCTitleIsCaptured() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        // ESC ] 0 ; <title> BEL
        var bytes: [UInt8] = [0x1B, 0x5D, 0x30, 0x3B]
        bytes.append(contentsOf: "✳ my-project".utf8)
        bytes.append(0x07)
        model.feed(Data(bytes))
        XCTAssertEqual(model.snapshot().oscTitle, "✳ my-project")
    }

    func testOSCProgressSetThenRemove() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        // OSC 9 ; 4 ; <state> ; <pct> ST  — SwiftTerm parses "4;<state>..." progress.
        func osc(_ payload: String) -> Data {
            var b: [UInt8] = [0x1B, 0x5D, 0x39, 0x3B]   // ESC ] 9 ;
            b.append(contentsOf: payload.utf8)
            b.append(0x07)
            return Data(b)
        }
        model.feed(osc("4;1;40"))
        XCTAssertTrue(model.snapshot().oscProgress.hasPrefix("4;1"), "set state should be reflected")
        model.feed(osc("4;0"))
        XCTAssertTrue(model.snapshot().oscProgress.hasPrefix("4;0"), "remove state maps to herdr's ^4;0 idle signal")
    }

    func testResizeDoesNotCrashAndKeepsContent() {
        let model = TerminalScreenModel(cols: 80, rows: 24)
        model.feed(Data("resize me".utf8))
        model.resize(cols: 100, rows: 30)
        XCTAssertTrue(model.snapshot().text.contains("resize me"))
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `swift test --filter TerminalScreenModelTests`
Expected: FAIL — "cannot find 'TerminalScreenModel' in scope".

- [ ] **Step 5: Implement `TerminalScreenModel`**

Create `Sources/ClaudeRelayServer/Detection/TerminalScreenModel.swift`:

```swift
import Foundation
import SwiftTerm

/// An immutable snapshot of the emulated screen at a point in time, plus the
/// two out-of-band OSC signals herdr's rules can key on.
struct ScreenSnapshot: Equatable {
    /// The visible grid rendered to text, one row per line, trailing blanks trimmed.
    let text: String
    /// The most recent OSC 0/2 window title, or "".
    let oscTitle: String
    /// The most recent OSC 9;4 progress payload rendered as "4;<state>[;<pct>]", or "".
    let oscProgress: String
}

/// Headless SwiftTerm emulator fed the same PTY byte stream the client sees, so
/// the server can read the *rendered* screen (not the raw escape soup) for
/// agent-state detection. One per PTY session; lives inside the PTYSession
/// actor's isolation domain (never touched concurrently).
final class TerminalScreenModel {

    /// Captures the terminal's title / progress callbacks. Retained STRONGLY
    /// because `Terminal.tdel` is a weak reference — a delegate that only the
    /// terminal held weakly would be released immediately and never fire.
    private final class Delegate: NSObject, TerminalDelegate {
        var oscTitle = ""
        var oscProgress = ""

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            // Detection is read-only: the emulator never needs to reply upstream.
        }

        func setTerminalTitle(source: Terminal, title: String) {
            oscTitle = title
        }

        func progressReport(source: Terminal, report: Terminal.ProgressReport) {
            switch report.state {
            case .remove:
                oscProgress = "4;0"
            case .set:
                oscProgress = "4;1;\(report.progress ?? 0)"
            case .error:
                oscProgress = "4;2;\(report.progress ?? 0)"
            case .indeterminate:
                oscProgress = "4;3"
            case .pause:
                oscProgress = "4;4;\(report.progress ?? 0)"
            }
        }
    }

    private let delegate = Delegate()
    private let terminal: Terminal

    init(cols: UInt16, rows: UInt16) {
        let options = TerminalOptions(cols: Int(cols), rows: Int(rows))
        terminal = Terminal(delegate: delegate, options: options)
    }

    /// Feed a chunk of raw PTY output into the emulator.
    func feed(_ data: Data) {
        terminal.feed(byteArray: [UInt8](data))
    }

    /// Resize the emulated grid to match a client resize.
    func resize(cols: UInt16, rows: UInt16) {
        terminal.resize(cols: Int(cols), rows: Int(rows))
    }

    /// Render the current visible grid + latest OSC signals into a snapshot.
    func snapshot() -> ScreenSnapshot {
        var lines: [String] = []
        lines.reserveCapacity(terminal.rows)
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else {
                lines.append("")
                continue
            }
            lines.append(line.translateToString(trimRight: true))
        }
        return ScreenSnapshot(
            text: lines.joined(separator: "\n"),
            oscTitle: delegate.oscTitle,
            oscProgress: delegate.oscProgress
        )
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter TerminalScreenModelTests`
Expected: PASS (5 tests). If `testOSCProgressSetThenRemove` fails on the exact OSC framing, adjust the test's escape bytes to SwiftTerm's accepted OSC 9;4 form — the production code path (Task 9) only reads `snapshot().oscProgress`, so the model API is what matters.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/ClaudeRelayServer/Detection/TerminalScreenModel.swift Sources/ClaudeRelayServer/Resources/Agents/.gitkeep Tests/ClaudeRelayServerTests/TerminalScreenModelTests.swift
git commit -m "feat(server): headless SwiftTerm screen model for agent detection

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 7: `ScreenRegion` slicers ported from herdr

**Files:**
- Create: `Sources/ClaudeRelayServer/Detection/ScreenRegion.swift`
- Test: `Tests/ClaudeRelayServerTests/ScreenRegionTests.swift`

**Interfaces:**
- Consumes: `ScreenSnapshot` (Task 6).
- Produces: `enum ScreenRegion { static func slice(_ spec: String, snapshot: ScreenSnapshot) -> String }` covering `whole_recent`, `osc_title`, `osc_progress`, `bottom_non_empty_lines(N)`, `after_last_horizontal_rule`, `prompt_box_body`, `after_last_prompt_marker`; plus `static func isHorizontalRule(_ line: String) -> Bool`.

> **Porting note (verified against herdr `src/detect/manifest.rs`):** Rust slices return byte substrings joined by the original `\n`. In Swift we operate on `text.split(separator: "\n", omittingEmptySubsequences: false)` and re-join with `"\n"`. A "non-empty line" is one whose `trimmingCharacters(in: .whitespaces)` is non-empty. `bottom_non_empty_lines(N)` returns from the Nth-from-last non-empty line to the end (inclusive of intervening blanks). `after_last_prompt_marker`: codex prompt line is exactly `"›"` or starts with `"› "`; whole content if none. `prompt_box_body`: lines strictly between the 2nd-from-bottom horizontal rule and the next rule below it (or end); empty if fewer than 2 rules. `after_last_horizontal_rule`: everything after the last rule line; whole content if none. `isHorizontalRule`: trimmed non-empty, begins with ≥1 `─` (U+2500), and the remainder after the leading run is empty OR the leading run is ≥3 chars.

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelayServerTests/ScreenRegionTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayServer

final class ScreenRegionTests: XCTestCase {

    private func snap(_ text: String, oscTitle: String = "", oscProgress: String = "") -> ScreenSnapshot {
        ScreenSnapshot(text: text, oscTitle: oscTitle, oscProgress: oscProgress)
    }

    func testWholeRecentReturnsFullText() {
        let s = snap("a\nb\nc")
        XCTAssertEqual(ScreenRegion.slice("whole_recent", snapshot: s), "a\nb\nc")
    }

    func testOSCRegionsSourceFromDedicatedFields() {
        let s = snap("screen text", oscTitle: "T", oscProgress: "4;0")
        XCTAssertEqual(ScreenRegion.slice("osc_title", snapshot: s), "T")
        XCTAssertEqual(ScreenRegion.slice("osc_progress", snapshot: s), "4;0")
    }

    func testBottomNonEmptyLines() {
        let s = snap("one\n\ntwo\nthree\n\n")
        // Last 2 non-empty lines are "two" and "three"; slice runs from "two" to end.
        XCTAssertEqual(ScreenRegion.slice("bottom_non_empty_lines(2)", snapshot: s), "two\nthree\n\n")
    }

    func testBottomNonEmptyLinesEmptyWhenNoContent() {
        XCTAssertEqual(ScreenRegion.slice("bottom_non_empty_lines(3)", snapshot: snap("\n\n")), "")
    }

    func testIsHorizontalRule() {
        XCTAssertTrue(ScreenRegion.isHorizontalRule("────────"))
        XCTAssertTrue(ScreenRegion.isHorizontalRule("─── Tools ───"))   // ≥3 leading + suffix
        XCTAssertFalse(ScreenRegion.isHorizontalRule("─ x"))            // 1 leading, non-empty suffix
        XCTAssertFalse(ScreenRegion.isHorizontalRule("plain text"))
        XCTAssertFalse(ScreenRegion.isHorizontalRule("   "))
    }

    func testAfterLastHorizontalRule() {
        let s = snap("top\n────\nmiddle\n────\nbottom line")
        XCTAssertEqual(ScreenRegion.slice("after_last_horizontal_rule", snapshot: s), "bottom line")
    }

    func testAfterLastHorizontalRuleWholeWhenNoRule() {
        let s = snap("no rules here\njust text")
        XCTAssertEqual(ScreenRegion.slice("after_last_horizontal_rule", snapshot: s), "no rules here\njust text")
    }

    func testPromptBoxBody() {
        // Two rules near the bottom; body is what sits strictly between the
        // 2nd-from-bottom rule and the next rule below it.
        let s = snap("history\n────\n❯ type here\n────\nesc to cancel")
        XCTAssertEqual(ScreenRegion.slice("prompt_box_body", snapshot: s), "❯ type here")
    }

    func testPromptBoxBodyEmptyWithoutTwoRules() {
        XCTAssertEqual(ScreenRegion.slice("prompt_box_body", snapshot: snap("just\none rule\n────")), "")
    }

    func testAfterLastPromptMarker() {
        let s = snap("history\n› old\nmiddle\n› \nafter marker")
        XCTAssertEqual(ScreenRegion.slice("after_last_prompt_marker", snapshot: s), "after marker")
    }

    func testAfterLastPromptMarkerWholeWhenNoMarker() {
        let s = snap("no prompt\nlines")
        XCTAssertEqual(ScreenRegion.slice("after_last_prompt_marker", snapshot: s), "no prompt\nlines")
    }

    func testUnknownRegionReturnsEmpty() {
        XCTAssertEqual(ScreenRegion.slice("nonsense_region", snapshot: snap("x")), "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ScreenRegionTests`
Expected: FAIL — "cannot find 'ScreenRegion' in scope".

- [ ] **Step 3: Implement `ScreenRegion`**

Create `Sources/ClaudeRelayServer/Detection/ScreenRegion.swift`:

```swift
import Foundation

/// Slices a `ScreenSnapshot` into the named region a manifest rule targets.
/// Ported from herdr's `src/detect/manifest.rs` region slicers. Operates on
/// line arrays (split on "\n", empty subsequences kept) and re-joins with "\n"
/// to mirror the Rust byte-substring behaviour.
enum ScreenRegion {

    static func slice(_ spec: String, snapshot: ScreenSnapshot) -> String {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "osc_title":   return snapshot.oscTitle
        case "osc_progress": return snapshot.oscProgress
        default: break
        }

        let content = snapshot.text
        switch trimmed {
        case "whole_recent":
            return content
        case "after_last_prompt_marker":
            return afterLastPromptMarker(content)
        case "prompt_box_body":
            return promptBoxBody(content)
        case "after_last_horizontal_rule":
            return afterLastHorizontalRule(content)
        default:
            if let count = regionCount(trimmed, prefix: "bottom_non_empty_lines") {
                return bottomNonEmptyLines(content, count: count)
            }
            return ""
        }
    }

    // MARK: - Rules

    /// herdr `is_horizontal_rule`: trimmed non-empty, starts with ≥1 U+2500
    /// box-drawing dash, and either the suffix after the leading run is empty
    /// or the leading run is ≥3 chars.
    static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let ruleChars = trimmed.prefix { $0 == "\u{2500}" }.count
        guard ruleChars > 0 else { return false }
        let suffix = String(trimmed.dropFirst(ruleChars)).trimmingCharacters(in: .whitespaces)
        return suffix.isEmpty || ruleChars >= 3
    }

    // MARK: - Slicers

    private static func lines(_ content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func isNonEmpty(_ line: String) -> Bool {
        !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func regionCount(_ spec: String, prefix: String) -> Int? {
        guard spec.hasPrefix(prefix + "("), spec.hasSuffix(")") else { return nil }
        let inner = spec.dropFirst(prefix.count + 1).dropLast()
        return Int(inner)
    }

    /// From the Nth-from-last non-empty line to the end (inclusive of blanks
    /// in between). Empty string if there are no non-empty lines.
    private static func bottomNonEmptyLines(_ content: String, count: Int) -> String {
        let all = lines(content)
        let nonEmptyIndices = all.indices.filter { isNonEmpty(all[$0]) }
        guard !nonEmptyIndices.isEmpty else { return "" }
        let startIndex = nonEmptyIndices.suffix(count).first ?? nonEmptyIndices[0]
        return all[startIndex...].joined(separator: "\n")
    }

    /// Everything after the last codex prompt line (`›` or `› …`); whole
    /// content if there is none.
    private static func afterLastPromptMarker(_ content: String) -> String {
        let all = lines(content)
        guard let index = all.lastIndex(where: isCodexPromptLine) else { return content }
        return all[(index + 1)...].joined(separator: "\n")
    }

    private static func isCodexPromptLine(_ line: String) -> Bool {
        line == "\u{203A}" || line.hasPrefix("\u{203A} ")
    }

    /// Everything after the last horizontal rule; whole content if none.
    private static func afterLastHorizontalRule(_ content: String) -> String {
        let all = lines(content)
        guard let index = all.lastIndex(where: isHorizontalRule) else { return content }
        return all[(index + 1)...].joined(separator: "\n")
    }

    /// Lines strictly between the 2nd-from-bottom horizontal rule and the next
    /// rule below it (or end). Empty if there are fewer than two rules.
    private static func promptBoxBody(_ content: String) -> String {
        let all = lines(content)
        guard let top = promptBoxTopBorderIndex(all) else { return "" }
        let rest = all[(top + 1)...]
        let endRelative = rest.firstIndex(where: isHorizontalRule) ?? all.endIndex
        return all[(top + 1)..<endRelative].joined(separator: "\n")
    }

    /// Index of the 2nd horizontal rule scanning from the bottom up.
    private static func promptBoxTopBorderIndex(_ all: [String]) -> Int? {
        var borderCount = 0
        for index in stride(from: all.count - 1, through: 0, by: -1) where isHorizontalRule(all[index]) {
            borderCount += 1
            if borderCount == 2 { return index }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ScreenRegionTests`
Expected: PASS (13 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayServer/Detection/ScreenRegion.swift Tests/ClaudeRelayServerTests/ScreenRegionTests.swift
git commit -m "feat(server): port herdr screen-region slicers

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 8: `AgentManifest`, `AgentStateDetector`, and the bundled JSON manifests

**Files:**
- Create: `Sources/ClaudeRelayServer/Detection/AgentManifest.swift`
- Create: `Sources/ClaudeRelayServer/Detection/AgentStateDetector.swift`
- Create: `Sources/ClaudeRelayServer/Resources/Agents/claude.json`
- Create: `Sources/ClaudeRelayServer/Resources/Agents/codex.json`
- Create: `Sources/ClaudeRelayServer/Resources/Agents/opencode.json`
- Test: `Tests/ClaudeRelayServerTests/AgentStateDetectorTests.swift`

**Interfaces:**
- Consumes: `ScreenSnapshot` (Task 6), `ScreenRegion` (Task 7), `AgentDetectedState` (Task 1).
- Produces:
  - `struct AgentDetection: Equatable { let state: AgentDetectedState; let skipStateUpdate: Bool; let visibleIdle: Bool; let visibleBlocker: Bool; let visibleWorking: Bool }`
  - `struct AgentManifest: Codable { let id: String; let rules: [AgentStateRule] }`
  - `struct AgentStateRule: Codable { let id: String; let state: String?; let priority: Int; let region: String; let skipStateUpdate: Bool; let visibleIdle/visibleBlocker/visibleWorking: Bool; gate fields }`
  - `final class AgentStateDetector { init(manifests: [String: AgentManifest]); func detect(agentId: String, snapshot: ScreenSnapshot) -> AgentDetection?; static func loadBundled() -> [String: AgentManifest] }`

> **Gate semantics (verified against herdr `compiled_gate_matches`):** a rule's top-level `contains`/`regex`/`lineRegex` and nested `all`/`any`/`not` gates all AND together. `contains` — every needle is a case-insensitive substring of the region. `regex` — every pattern matches (whole region, multiline). `lineRegex` — every pattern matches at least one line. `all` — every nested gate matches. `any` — enforced only if non-empty; then ≥1 nested must match. `not` — no nested gate may match. Rule selection: highest `priority` wins; on a tie, the FIRST rule in manifest order wins (replace only when `previous.priority < rule.priority`). No rule matches + known agent → fallback `.idle` with all visible flags false. `skipStateUpdate` rules, when they win, return a detection whose `skipStateUpdate` is true (the arbiter freezes current state). Rust regex `\x{2800}` → Swift `NSRegularExpression` `\u{2800}`.

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelayServerTests/AgentStateDetectorTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class AgentStateDetectorTests: XCTestCase {

    private func snap(_ text: String, oscTitle: String = "", oscProgress: String = "") -> ScreenSnapshot {
        ScreenSnapshot(text: text, oscTitle: oscTitle, oscProgress: oscProgress)
    }

    // MARK: - Bundled manifests load

    func testBundledManifestsLoad() {
        let manifests = AgentStateDetector.loadBundled()
        XCTAssertNotNil(manifests["claude"])
        XCTAssertNotNil(manifests["codex"])
        XCTAssertNotNil(manifests["opencode"])
    }

    // MARK: - claude rules

    func testClaudeBlockedOnBashPermissionPrompt() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        Running a bash command
        Do you want to proceed?
        ❯ 1. Yes
          2. No
        """
        let detection = detector.detect(agentId: "claude", snapshot: snap(screen))
        XCTAssertEqual(detection?.state, .blocked)
        XCTAssertTrue(detection?.visibleBlocker ?? false)
    }

    func testClaudeWorkingFromOSCSpinnerTitle() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        // Braille spinner char U+2801 + space prefix in the title.
        let detection = detector.detect(agentId: "claude", snapshot: snap("", oscTitle: "\u{2801} building"))
        XCTAssertEqual(detection?.state, .working)
        XCTAssertTrue(detection?.visibleWorking ?? false)
    }

    func testClaudeIdleFromPromptBox() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        earlier output
        ────
        ❯ 
        ────
        """
        let detection = detector.detect(agentId: "claude", snapshot: snap(screen))
        XCTAssertEqual(detection?.state, .idle)
    }

    func testClaudeTranscriptViewerSkipsStateUpdate() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = "showing detailed transcript\n↑↓ scroll"
        let detection = detector.detect(agentId: "claude", snapshot: snap(screen))
        XCTAssertTrue(detection?.skipStateUpdate ?? false)
    }

    func testClaudeFallbackIsIdleWhenNothingMatches() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "claude", snapshot: snap("just some plain output"))
        XCTAssertEqual(detection?.state, .idle)
        XCTAssertFalse(detection?.visibleIdle ?? true)
    }

    // MARK: - codex rules

    func testCodexBlockedFromOSCTitle() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "codex", snapshot: snap("", oscTitle: "Action Required"))
        XCTAssertEqual(detection?.state, .blocked)
    }

    func testCodexWorkingFromScreenFallback() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "codex", snapshot: snap("• Working (12s · esc to interrupt)"))
        XCTAssertEqual(detection?.state, .working)
    }

    // MARK: - opencode rules

    func testOpencodeBlockedOnPermissionRequired() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "opencode", snapshot: snap("△ Permission required"))
        XCTAssertEqual(detection?.state, .blocked)
    }

    func testOpencodeWorkingFromInterruptHint() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "opencode", snapshot: snap("press esc to interrupt"))
        XCTAssertEqual(detection?.state, .working)
    }

    // MARK: - unknown agent

    func testUnknownAgentReturnsNil() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        XCTAssertNil(detector.detect(agentId: "not-an-agent", snapshot: snap("x")))
    }

    // MARK: - priority tie-break

    func testHigherPriorityWins() {
        // A synthetic 2-rule manifest: both match, higher priority must win.
        let json = """
        {"id":"t","rules":[
          {"id":"low","state":"idle","priority":100,"region":"whole_recent","contains":["x"]},
          {"id":"high","state":"blocked","priority":900,"region":"whole_recent","contains":["x"]}
        ]}
        """
        let manifest = try! JSONDecoder().decode(AgentManifest.self, from: Data(json.utf8))
        let detector = AgentStateDetector(manifests: ["t": manifest])
        XCTAssertEqual(detector.detect(agentId: "t", snapshot: snap("x"))?.state, .blocked)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AgentStateDetectorTests`
Expected: FAIL — "cannot find 'AgentStateDetector' / 'AgentManifest' / 'AgentDetection' in scope".

- [ ] **Step 3: Implement `AgentManifest.swift`**

Create `Sources/ClaudeRelayServer/Detection/AgentManifest.swift`:

```swift
import Foundation

/// The outcome of evaluating an agent's manifest against a screen snapshot.
/// Mirrors herdr's `AgentDetection`.
struct AgentDetection: Equatable {
    let state: AgentDetectedState
    /// When true, the winning rule was a "viewer/menu overlay" — the arbiter
    /// must freeze the session's current state rather than adopt this one.
    let skipStateUpdate: Bool
    let visibleIdle: Bool
    let visibleBlocker: Bool
    let visibleWorking: Bool
}

/// A recursive match gate. All present fields AND together (see
/// `AgentStateRule.matches`).
struct AgentGate: Codable {
    var contains: [String]?
    var regex: [String]?
    var lineRegex: [String]?
    var all: [AgentGate]?
    var any: [AgentGate]?
    var not: [AgentGate]?
}

/// One detection rule. `state` is nil only for `skip_state_update` overlays
/// that don't assert a state (herdr's `unknown`).
struct AgentStateRule: Codable {
    let id: String
    let state: String?
    let priority: Int
    let region: String
    var skipStateUpdate: Bool?
    var visibleIdle: Bool?
    var visibleBlocker: Bool?
    var visibleWorking: Bool?
    // Top-level gate fields (a rule is itself a gate plus routing metadata).
    var contains: [String]?
    var regex: [String]?
    var lineRegex: [String]?
    var all: [AgentGate]?
    var any: [AgentGate]?
    var not: [AgentGate]?

    private enum CodingKeys: String, CodingKey {
        case id, state, priority, region
        case skipStateUpdate = "skip_state_update"
        case visibleIdle = "visible_idle"
        case visibleBlocker = "visible_blocker"
        case visibleWorking = "visible_working"
        case contains, regex
        case lineRegex = "line_regex"
        case all, any, not
    }

    /// The rule's own gate, assembled from its top-level gate fields.
    var gate: AgentGate {
        AgentGate(contains: contains, regex: regex, lineRegex: lineRegex, all: all, any: any, not: not)
    }

    var resolvedState: AgentDetectedState {
        state.flatMap(AgentDetectedState.init(rawValue:)) ?? .unknown
    }
}

/// A per-agent set of ordered rules.
struct AgentManifest: Codable {
    let id: String
    let rules: [AgentStateRule]
}
```

- [ ] **Step 4: Implement `AgentStateDetector.swift`**

Create `Sources/ClaudeRelayServer/Detection/AgentStateDetector.swift`:

```swift
import Foundation

/// Evaluates a screen snapshot against an agent's manifest and returns the
/// winning detection. Ported from herdr's `evaluate_loaded_manifest` +
/// `compiled_gate_matches`. Regexes are compiled once at init.
final class AgentStateDetector {

    private let manifests: [String: AgentManifest]
    /// Cache: "<pattern>" -> compiled NSRegularExpression (dotMatchesLineSeparators
    /// on so `.` spans the joined multi-line region, matching Rust's default).
    private var regexCache: [String: NSRegularExpression] = [:]

    init(manifests: [String: AgentManifest]) {
        self.manifests = manifests
        // Warm the cache so the hot detect() path never compiles.
        for manifest in manifests.values {
            for rule in manifest.rules {
                warm(rule.gate)
            }
        }
    }

    /// Detect the agent's state. Returns nil for an unknown agent id (herdr's
    /// "nil agent → Unknown"; callers treat nil as "no manifest, skip").
    func detect(agentId: String, snapshot: ScreenSnapshot) -> AgentDetection? {
        guard let manifest = manifests[agentId] else { return nil }

        var winner: AgentStateRule?
        for rule in manifest.rules {
            let region = ScreenRegion.slice(rule.region, snapshot: snapshot)
            guard matches(rule.gate, text: region) else { continue }
            if let current = winner {
                if current.priority < rule.priority { winner = rule }
            } else {
                winner = rule
            }
        }

        guard let rule = winner else {
            // No rule matched: known agent falls back to Idle, all flags off.
            return AgentDetection(state: .idle, skipStateUpdate: false,
                                  visibleIdle: false, visibleBlocker: false, visibleWorking: false)
        }

        let state = rule.resolvedState
        return AgentDetection(
            state: state,
            skipStateUpdate: rule.skipStateUpdate ?? false,
            visibleIdle: (rule.visibleIdle ?? false) && state == .idle,
            visibleBlocker: (rule.visibleBlocker ?? false) && state == .blocked,
            visibleWorking: (rule.visibleWorking ?? false) && state == .working
        )
    }

    // MARK: - Gate matching (herdr compiled_gate_matches)

    private func matches(_ gate: AgentGate, text: String) -> Bool {
        let lower = text.lowercased()

        if let contains = gate.contains, !contains.allSatisfy({ lower.contains($0.lowercased()) }) {
            return false
        }
        if let patterns = gate.regex, !patterns.allSatisfy({ regexMatches($0, in: text) }) {
            return false
        }
        if let patterns = gate.lineRegex {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let allMatch = patterns.allSatisfy { pattern in
                lines.contains { regexMatches(pattern, in: $0) }
            }
            if !allMatch { return false }
        }
        if let all = gate.all, !all.allSatisfy({ matches($0, text: text) }) {
            return false
        }
        if let any = gate.any, !any.isEmpty, !any.contains(where: { matches($0, text: text) }) {
            return false
        }
        if let not = gate.not, not.contains(where: { matches($0, text: text) }) {
            return false
        }
        return true
    }

    // MARK: - Regex cache

    private func warm(_ gate: AgentGate) {
        (gate.regex ?? []).forEach { _ = compiled($0) }
        (gate.lineRegex ?? []).forEach { _ = compiled($0) }
        (gate.all ?? []).forEach(warm)
        (gate.any ?? []).forEach(warm)
        (gate.not ?? []).forEach(warm)
    }

    private func compiled(_ pattern: String) -> NSRegularExpression? {
        if let cached = regexCache[pattern] { return cached }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            RelayLogger.log(.error, category: "detection", "Bad manifest regex: \(pattern)")
            return nil
        }
        regexCache[pattern] = re
        return re
    }

    private func regexMatches(_ pattern: String, in text: String) -> Bool {
        guard let re = compiled(pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }

    // MARK: - Bundled manifest loading

    /// Load the three bundled JSON manifests from the target's resource bundle,
    /// then overlay any user override in `~/.claude-relay/agents/<id>.json`.
    static func loadBundled() -> [String: AgentManifest] {
        var result: [String: AgentManifest] = [:]
        let decoder = JSONDecoder()

        for id in ["claude", "codex", "opencode"] {
            guard let url = Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "Agents"),
                  let data = try? Data(contentsOf: url),
                  let manifest = try? decoder.decode(AgentManifest.self, from: data) else {
                RelayLogger.log(.error, category: "detection", "Failed to load bundled manifest: \(id)")
                continue
            }
            result[id] = manifest
        }

        // User overrides shadow bundled manifests by agent id.
        let overrideDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-relay/agents", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(at: overrideDir, includingPropertiesForKeys: nil) {
            for url in entries where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let manifest = try? decoder.decode(AgentManifest.self, from: data) else {
                    RelayLogger.log(.error, category: "detection", "Bad override manifest: \(url.lastPathComponent)")
                    continue
                }
                result[manifest.id] = manifest
            }
        }

        return result
    }
}
```

- [ ] **Step 5: Write the three bundled JSON manifests**

Create `Sources/ClaudeRelayServer/Resources/Agents/claude.json` (translated from `claude.toml`; Rust `\x{2800}` → JSON `⠀`, and each JSON-escaped backslash is doubled in the pattern string):

```json
{
  "id": "claude",
  "rules": [
    { "id": "osc_title_working", "state": "working", "priority": 1100, "region": "osc_title", "visible_working": true, "regex": ["^[\\u2800-\\u28FF] "] },
    { "id": "btw_overlay_working", "state": "working", "priority": 975, "region": "bottom_non_empty_lines(5)", "visible_working": true, "line_regex": ["^\\s*/btw(?:\\s|$)", "(?i)esc to close\\s*$"] },
    { "id": "transcript_viewer", "state": "unknown", "priority": 1000, "region": "bottom_non_empty_lines(3)", "skip_state_update": true, "contains": ["showing detailed transcript"], "any": [ {"contains": ["ctrl+o", "to toggle"]}, {"contains": ["ctrl+e", "show all"]}, {"contains": ["ctrl+e", "collapse"]}, {"contains": ["↑↓ scroll"]}, {"contains": ["? for shortcuts"]} ] },
    { "id": "live_blocked_form", "state": "blocked", "priority": 980, "region": "after_last_horizontal_rule", "visible_blocker": true, "contains": ["enter to select", "esc to cancel"], "any": [ {"contains": ["tab/arrow keys to navigate"]}, {"contains": ["arrow keys to navigate"]}, {"contains": ["arrows to navigate"]}, {"contains": ["↑/↓ to navigate"]}, {"contains": ["↑↓ to navigate"]} ] },
    { "id": "dynamic_workflow_prompt", "state": "blocked", "priority": 980, "region": "whole_recent", "visible_blocker": true, "contains": ["run a dynamic workflow?", "esc to cancel"] },
    { "id": "live_prompt_box", "state": "idle", "priority": 950, "region": "prompt_box_body", "visible_idle": true, "line_regex": ["^\\s*❯"], "not": [ {"contains": ["enter to select"]}, {"contains": ["esc to cancel"]}, {"contains": ["tab/arrow keys"]}, {"contains": ["arrow keys to navigate"]}, {"contains": ["↑/↓ to navigate"]} ] },
    { "id": "model_picker_menu", "state": "unknown", "priority": 900, "region": "whole_recent", "skip_state_update": true, "contains": ["select model", "enter to set as default", "esc to cancel"], "not": [ {"contains": ["do you want to proceed?"]}, {"contains": ["enter to select"]} ] },
    { "id": "bash_permission_prompt", "state": "blocked", "priority": 850, "region": "whole_recent", "visible_blocker": true, "contains": ["do you want to proceed?"], "any": [ {"contains": ["bash command"]}, {"contains": ["bash("]}, {"contains": ["contains expansion"]}, {"contains": ["tab to amend"]}, {"contains": ["ctrl+e to explain"]} ], "all": [ {"any": [ {"line_regex": ["(?i)^\\s*❯?\\s*yes\\b"]}, {"line_regex": ["(?i)^\\s*1\\.\\s*yes\\b"]}, {"line_regex": ["(?i)^\\s*2\\.\\s*no\\b"]} ]} ] },
    { "id": "generic_permission_prompt", "state": "blocked", "priority": 840, "region": "after_last_horizontal_rule", "visible_blocker": true, "contains": ["do you want to proceed?", "esc to cancel"], "all": [ {"any": [ {"line_regex": ["(?i)^\\s*❯?\\s*1\\.\\s*yes\\b"]}, {"line_regex": ["(?i)^\\s*2\\.\\s*yes\\b"]}, {"line_regex": ["(?i)^\\s*2\\.\\s*no\\b"]}, {"line_regex": ["(?i)^\\s*3\\.\\s*no\\b"]} ]} ] },
    { "id": "legacy_no_prompt_blocker", "state": "blocked", "priority": 300, "region": "whole_recent", "any": [ {"contains": ["do you want to"], "any": [ {"contains": ["yes"]}, {"contains": ["❯"]} ]}, {"contains": ["would you like to"], "any": [ {"contains": ["yes"]}, {"contains": ["❯"]} ]}, {"contains": ["waiting for permission"]}, {"contains": ["do you want to allow this connection?"]}, {"contains": ["tab to amend"]}, {"contains": ["ctrl+e to explain"]}, {"contains": ["do you want to proceed?", "esc to cancel"]}, {"contains": ["review your answers"]}, {"contains": ["skip interview and plan immediately"]} ], "not": [ {"regex": ["(?m)^\\s*❯\\s*$"]} ] },
    { "id": "osc_title_idle", "state": "idle", "priority": 250, "region": "osc_title", "visible_idle": true, "regex": ["^\\u2733 "] },
    { "id": "osc_progress_idle", "state": "idle", "priority": 250, "region": "osc_progress", "regex": ["^4;0"] }
  ]
}
```

Create `Sources/ClaudeRelayServer/Resources/Agents/codex.json` (from `codex.toml`):

```json
{
  "id": "codex",
  "rules": [
    { "id": "osc_title_blocked", "state": "blocked", "priority": 1100, "region": "osc_title", "visible_blocker": true, "contains": ["Action Required"] },
    { "id": "osc_title_working", "state": "working", "priority": 1050, "region": "osc_title", "visible_working": true, "regex": ["(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)"] },
    { "id": "transcript_viewer", "state": "unknown", "priority": 1000, "region": "after_last_prompt_marker", "skip_state_update": true, "contains": ["↑/↓ to scroll", "pgup/pgdn to", "home/end to jump", "q to quit"], "any": [ {"contains": ["esc to edit prev"]}, {"contains": ["esc/← to edit prev"]} ] },
    { "id": "live_strong_blocker", "state": "blocked", "priority": 900, "region": "after_last_prompt_marker", "visible_blocker": true, "any": [ {"contains": ["press enter to confirm or esc to cancel"]}, {"contains": ["enter to submit answer"]}, {"contains": ["enter to submit all"]}, {"contains": ["allow command?"]} ] },
    { "id": "weak_blocker", "state": "blocked", "priority": 600, "region": "whole_recent", "any": [ {"contains": ["[y/n]"]}, {"contains": ["yes (y)"]}, {"contains": ["do you want to"], "any": [ {"contains": ["yes"]}, {"contains": ["❯"]} ]}, {"contains": ["would you like to"], "any": [ {"contains": ["yes"]}, {"contains": ["❯"]} ]} ] },
    { "id": "screen_working_fallback", "state": "working", "priority": 500, "region": "bottom_non_empty_lines(3)", "visible_working": true, "line_regex": ["^[•◦]\\s+Working \\([^)]*esc to interrupt\\)(?: · .*)?$"], "not": [ {"contains": ["■ Conversation interrupted"]} ] },
    { "id": "osc_title_idle", "state": "idle", "priority": 100, "region": "osc_title", "visible_idle": true, "regex": ["\\S"], "not": [ {"regex": ["(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)"]}, {"contains": ["Action Required"]} ] }
  ]
}
```

Create `Sources/ClaudeRelayServer/Resources/Agents/opencode.json` (from `opencode.toml`):

```json
{
  "id": "opencode",
  "rules": [
    { "id": "permission_required", "state": "blocked", "priority": 300, "region": "whole_recent", "visible_blocker": true, "any": [ {"contains": ["△ Permission required"]}, {"contains": ["esc dismiss"], "any": [ {"contains": ["enter confirm"]}, {"contains": ["enter submit"]}, {"contains": ["enter toggle"]} ], "all": [ {"any": [ {"contains": ["↑↓ select"]}, {"contains": ["⇆ tab"]} ]} ]} ] },
    { "id": "interrupt_hint_working", "state": "working", "priority": 110, "region": "whole_recent", "visible_working": true, "any": [ {"contains": ["esc to interrupt"]}, {"contains": ["ctrl+c to interrupt"]}, {"contains": ["press esc to interrupt"]}, {"line_regex": ["(?i).*opencode.*esc (again to )?interrupt"]} ] },
    { "id": "progress_bar_working", "state": "working", "priority": 100, "region": "whole_recent", "visible_working": true, "regex": ["(■|⬝){4,}"] }
  ]
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter AgentStateDetectorTests`
Expected: PASS (12 tests). If `testClaudeWorkingFromOSCSpinnerTitle` fails, verify the JSON regex escaping survived the decode — the compiled pattern must be `^[⠀-⣿] ` (a single backslash reaching NSRegularExpression).

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeRelayServer/Detection/AgentManifest.swift Sources/ClaudeRelayServer/Detection/AgentStateDetector.swift Sources/ClaudeRelayServer/Resources/Agents/*.json Tests/ClaudeRelayServerTests/AgentStateDetectorTests.swift
git rm --cached Sources/ClaudeRelayServer/Resources/Agents/.gitkeep 2>/dev/null || true
git commit -m "feat(server): manifest-driven agent state detector + bundled manifests

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 9: Arbiter in `SessionActivityMonitor` + PTYSession integration + `.opencode`

**Files:**
- Modify: `Sources/ClaudeRelayKit/Models/CodingAgent.swift`
- Modify: `Sources/ClaudeRelayServer/Actors/SessionActivityMonitor.swift`
- Modify: `Sources/ClaudeRelayServer/Actors/PTYSession.swift`
- Test: `Tests/ClaudeRelayServerTests/AgentStateArbiterTests.swift` (create)
- Test: `Tests/ClaudeRelayKitTests/CodingAgentTests.swift` (append if present; else create)

**Interfaces:**
- Consumes: `AgentStateDetector`, `AgentDetection`, `ScreenSnapshot`, `TerminalScreenModel` (Tasks 6-8); widened monitor `onChange` (Task 4).
- Produces:
  - `CodingAgent.opencode`; `CodingAgent.all == [.claude, .codex, .opencode]`.
  - `SessionActivityMonitor.updateScreenDetection(_ detection: AgentDetection?, now: Date)` — applies the anti-flap arbiter and, on a publishable change, sets `agentState`/(clears via agent-exit) and emits `onChange`.
  - `PTYSession`: constructs a `TerminalScreenModel`, feeds it in `handleOutput`, and on each foreground-poll tick takes a snapshot, runs the detector for the active agent, and calls `updateScreenDetection`.

> **Arbiter rules (verified against herdr `agent_detection.rs`):** pending-idle hold applies ONLY to a Working→plain-Idle transition (next state `.idle`, no visible idle/blocker, agent unchanged, process not exited): hold up to 700 ms OR 3 confirmations before publishing idle. `skipStateUpdate` detections freeze the current `agentState` (publish nothing). A 3 s startup grace after agent entry suppresses spurious idle. On agent exit, force `.idle`. On agent change, clear stale OSC-derived state.

- [ ] **Step 1: Write the failing test for `.opencode`**

Append to `Tests/ClaudeRelayKitTests/CodingAgentTests.swift` (create the file with this content if it doesn't exist):

```swift
import XCTest
@testable import ClaudeRelayKit

final class CodingAgentTests: XCTestCase {
    func testOpencodeIsRegistered() {
        XCTAssertNotNil(CodingAgent.find(id: "opencode"))
        XCTAssertEqual(CodingAgent.matching(processName: "opencode")?.id, "opencode")
        XCTAssertEqual(CodingAgent.matching(title: "opencode session")?.id, "opencode")
    }

    func testAllContainsThreeAgents() {
        XCTAssertEqual(Set(CodingAgent.all.map { $0.id }), ["claude", "codex", "opencode"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CodingAgentTests`
Expected: FAIL — `find(id: "opencode")` returns nil; `all` has 2 agents.

- [ ] **Step 3: Add `.opencode` to the registry**

In `Sources/ClaudeRelayKit/Models/CodingAgent.swift`, add after `codex` (after line 78):
```swift
    public static let opencode = CodingAgent(
        id: "opencode", displayName: "opencode",
        processNames: ["opencode"], titleKeywords: ["opencode"]
    )
```
Change `all` (line 80):
```swift
    public static let all: [CodingAgent] = [.claude, .codex, .opencode]
```

- [ ] **Step 4: Run the `.opencode` test to verify it passes**

Run: `swift test --filter CodingAgentTests`
Expected: PASS.

- [ ] **Step 5: Write the failing arbiter test**

Create `Tests/ClaudeRelayServerTests/AgentStateArbiterTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class AgentStateArbiterTests: XCTestCase {

    /// Build a monitor already "inside an agent" so screen detection applies.
    /// `entryDate` stamps agent entry with a CONTROLLED clock so the 3s startup
    /// grace is computed against the same fake timeline the test passes to
    /// `updateScreenDetection` (a real `Date()` entry vs. a 1970 `now` would
    /// make every idle look "within startup grace" and be suppressed).
    private func makeAgentMonitor(
        entryDate: Date,
        onChange: @escaping @Sendable (AgentDetectedState?) -> Void
    ) -> SessionActivityMonitor {
        let monitor = SessionActivityMonitor(
            silenceThreshold: 10, agentSilenceThreshold: 10,
            onChange: { _, _, agentState, _, _ in onChange(agentState) }
        )
        monitor.updateForegroundProcess(agent: .claude, now: entryDate)   // enter agent
        return monitor
    }

    private func detection(_ state: AgentDetectedState, visibleIdle: Bool = false,
                           visibleBlocker: Bool = false, visibleWorking: Bool = false,
                           skip: Bool = false) -> AgentDetection {
        AgentDetection(state: state, skipStateUpdate: skip,
                       visibleIdle: visibleIdle, visibleBlocker: visibleBlocker, visibleWorking: visibleWorking)
    }

    func testBlockedPublishesImmediately() {
        var last: AgentDetectedState?
        let entry = Date(timeIntervalSince1970: 100)
        let monitor = makeAgentMonitor(entryDate: entry) { last = $0 }
        // Past the 3s startup grace.
        monitor.updateScreenDetection(detection(.blocked, visibleBlocker: true), now: entry.addingTimeInterval(5))
        XCTAssertEqual(last, .blocked)
    }

    func testSkipStateUpdateFreezesState() {
        var updates: [AgentDetectedState?] = []
        let entry = Date(timeIntervalSince1970: 100)
        let monitor = makeAgentMonitor(entryDate: entry) { updates.append($0) }
        let base = entry.addingTimeInterval(5)
        monitor.updateScreenDetection(detection(.working, visibleWorking: true), now: base)
        updates.removeAll()
        // A transcript-viewer overlay must not change the published state.
        monitor.updateScreenDetection(detection(.unknown, skip: true), now: base.addingTimeInterval(1))
        XCTAssertTrue(updates.isEmpty, "skipStateUpdate must not emit a new agentState")
    }

    func testWorkingToPlainIdleIsHeldThenConfirmed() {
        var last: AgentDetectedState?
        let entry = Date(timeIntervalSince1970: 100)
        let monitor = makeAgentMonitor(entryDate: entry) { last = $0 }
        let t0 = entry.addingTimeInterval(5)
        monitor.updateScreenDetection(detection(.working, visibleWorking: true), now: t0)
        last = nil
        // First plain-idle: held (no publish).
        monitor.updateScreenDetection(detection(.idle), now: t0.addingTimeInterval(0.1))
        XCTAssertNil(last, "first Working→plain-idle is held")
        // After the 700ms cap, idle is published.
        monitor.updateScreenDetection(detection(.idle), now: t0.addingTimeInterval(0.8))
        XCTAssertEqual(last, .idle)
    }

    func testVisibleIdleBypassesHold() {
        var last: AgentDetectedState?
        let entry = Date(timeIntervalSince1970: 100)
        let monitor = makeAgentMonitor(entryDate: entry) { last = $0 }
        let t0 = entry.addingTimeInterval(5)
        monitor.updateScreenDetection(detection(.working, visibleWorking: true), now: t0)
        last = nil
        // A visible idle prompt box is authoritative — publish immediately.
        monitor.updateScreenDetection(detection(.idle, visibleIdle: true), now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(last, .idle)
    }
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `swift test --filter AgentStateArbiterTests`
Expected: FAIL — `updateScreenDetection` doesn't exist.

- [ ] **Step 7: Implement the arbiter in `SessionActivityMonitor`**

In `Sources/ClaudeRelayServer/Actors/SessionActivityMonitor.swift`:

Add arbiter state after `title` (near the other stored properties, after the `title` property from Task 4):
```swift
    // MARK: - Screen-Detection Arbiter (Phase 2)

    private var agentEnteredAt: Date?
    private var pendingIdleStartedAt: Date?
    private var pendingIdleConfirmations: Int = 0
    private var lastVisibleIdle = false
    private var lastVisibleBlocker = false
    private var lastVisibleWorking = false
    private static let pendingIdleCap: TimeInterval = 0.7
    private static let pendingIdleConfirmationLimit = 3
    private static let startupGrace: TimeInterval = 3.0
```

Widen `updateForegroundProcess` to take an injectable clock (defaulted to `Date()` so the PTY call and existing tests are unaffected) and stamp entry time when an agent newly appears. Change the method signature (line 144) and the `if activeAgent?.id != agent.id {` block (around line 148):
```swift
    public func updateForegroundProcess(agent: CodingAgent?, now: Date = Date()) {
        guard !cancelled else { return }
        if let agent {
            consecutiveNoAgentPolls = 0
            if activeAgent?.id != agent.id {
                activeAgent = agent
                agentEnteredAt = now
                agentState = nil            // clear stale detection on agent change
                pendingIdleStartedAt = nil
                pendingIdleConfirmations = 0
                transition(to: .agentActive)
                resetSilenceTimer()
            }
        } else if activeAgent != nil {
```
(The existing `consecutiveNoAgentPolls += 1` / `exitAgent()` tail of the method is unchanged.)

In `exitAgent()` (line 213) and `forceExit()` (line 117), clear the fine-grained state. Add to `exitAgent()`:
```swift
    private func exitAgent() {
        activeAgent = nil
        consecutiveNoAgentPolls = 0
        agentState = nil
        agentEnteredAt = nil
        pendingIdleStartedAt = nil
        transition(to: .active)
        resetSilenceTimer()
    }
```
Replace `forceExit()` (lines 117-126) in full so the arbiter state is cleared and idle is forced:
```swift
    public func forceExit() {
        guard !cancelled else { return }
        silenceTask?.cancel()
        silenceTask = nil
        if activeAgent != nil {
            activeAgent = nil
            consecutiveNoAgentPolls = 0
        }
        agentState = .idle          // process gone: definitively idle
        agentEnteredAt = nil
        pendingIdleStartedAt = nil
        pendingIdleConfirmations = 0
        transition(to: .idle)
    }
```

Add the arbiter method (place it after `updateForegroundProcess`):
```swift
    /// Apply a screen-detection result with herdr's anti-flap arbitration.
    /// Called from PTYSession on each foreground-poll tick with the detector's
    /// output for the active agent (nil when no agent / no manifest).
    public func updateScreenDetection(_ detection: AgentDetection?, now: Date) {
        guard !cancelled, activeAgent != nil, let detection else { return }

        // Overlay (transcript viewer, model picker): freeze current state.
        if detection.skipStateUpdate { return }

        // Startup grace: ignore a spurious idle right after agent entry.
        if let enteredAt = agentEnteredAt,
           detection.state == .idle, !detection.visibleIdle,
           now.timeIntervalSince(enteredAt) < Self.startupGrace {
            return
        }

        let previousState = agentState
        let next = detection.state

        // Pending-idle hold: only Working→plain-idle, not a visible idle/blocker.
        let isWorkingToPlainIdle = previousState == .working
            && next == .idle && !detection.visibleIdle && !detection.visibleBlocker
        if isWorkingToPlainIdle {
            if shouldHoldPlainIdle(now: now) { return }
        } else {
            pendingIdleStartedAt = nil
            pendingIdleConfirmations = 0
        }

        let changed = next != previousState
            || detection.visibleIdle != lastVisibleIdle
            || detection.visibleBlocker != lastVisibleBlocker
            || detection.visibleWorking != lastVisibleWorking
        guard changed else { return }

        lastVisibleIdle = detection.visibleIdle
        lastVisibleBlocker = detection.visibleBlocker
        lastVisibleWorking = detection.visibleWorking
        agentState = next
        revision &+= 1
        onChange(state, activeAgent, agentState, title, revision)
    }

    /// Returns true while a Working→plain-idle transition should be withheld.
    /// Publishes (returns false) once 700ms elapse or 3 confirmations accrue.
    private func shouldHoldPlainIdle(now: Date) -> Bool {
        guard let startedAt = pendingIdleStartedAt else {
            pendingIdleStartedAt = now
            pendingIdleConfirmations = 0
            return true
        }
        if now.timeIntervalSince(startedAt) >= Self.pendingIdleCap {
            pendingIdleStartedAt = nil
            pendingIdleConfirmations = 0
            return false
        }
        pendingIdleConfirmations += 1
        if pendingIdleConfirmations >= Self.pendingIdleConfirmationLimit {
            pendingIdleStartedAt = nil
            pendingIdleConfirmations = 0
            return false
        }
        return true
    }
```

Also feed the title into `agentState` publishing by having `handleTitle` refresh `title`. In `handleTitle(_:)` (line 197), add at the top:
```swift
    private func handleTitle(_ title: String) {
        self.title = title
```

- [ ] **Step 8: Integrate into `PTYSession`**

In `Sources/ClaudeRelayServer/Actors/PTYSession.swift`:

Add a stored screen model + detector near `activityMonitor` (after line 79):
```swift
    private let screenModel: TerminalScreenModel
    private let stateDetector: AgentStateDetector
```

Construct them in `init` after the monitor is built (after line 196):
```swift
        self.screenModel = TerminalScreenModel(cols: cols, rows: rows)
        self.stateDetector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
```
(Order: `screenModel`/`stateDetector` are `let`s with no dependency on `self`; assign them alongside `activityMonitor`. Swift requires all stored properties initialized before the initializer returns — placing these right after the `activityMonitor` assignment satisfies that.)

Feed the model in `handleOutput` (lines 352-356):
```swift
    private func handleOutput(_ data: Data) {
        ringBuffer.write(data)
        screenModel.feed(data)
        activityMonitor.processOutput(data)
        outputHandler?(data)
    }
```

Feed resizes to the model in `resize` (after line 495):
```swift
    public func resize(cols: UInt16, rows: UInt16) {
        guard !terminated else { return }
        currentCols = cols
        currentRows = rows
        screenModel.resize(cols: cols, rows: rows)
        _ = relay_set_winsize(masterFD, rows, cols)
    }
```

Run detection on the foreground-poll result. Replace `handleForegroundPollResult` (lines 223-226):
```swift
    private func handleForegroundPollResult(agent: CodingAgent?) {
        guard !terminated else { return }
        activityMonitor.updateForegroundProcess(agent: agent)
        // Screen detection only runs while an agent is active. Snapshot the
        // emulated grid and evaluate the agent's manifest, then arbitrate.
        if let agent = activityMonitor.activeAgent {
            let snapshot = screenModel.snapshot()
            let detection = stateDetector.detect(agentId: agent.id, snapshot: snapshot)
            activityMonitor.updateScreenDetection(detection, now: Date())
        }
    }
```

- [ ] **Step 9: Run all affected suites**

Run: `swift test --filter AgentStateArbiterTests`
Expected: PASS (4 tests).

Run: `swift build && swift test --filter SessionActivityMonitorTests && swift test --filter SessionObserverTests`
Expected: PASS — existing monitor/observer tests unaffected (the arbiter path only fires via `updateScreenDetection`, which those suites don't call).

- [ ] **Step 10: Commit**

```bash
git add Sources/ClaudeRelayKit/Models/CodingAgent.swift Sources/ClaudeRelayServer/Actors/SessionActivityMonitor.swift Sources/ClaudeRelayServer/Actors/PTYSession.swift Tests/ClaudeRelayServerTests/AgentStateArbiterTests.swift Tests/ClaudeRelayKitTests/CodingAgentTests.swift
git commit -m "feat(server): screen-detection arbiter + opencode agent + PTY integration

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 10: Richer sidebar UI on both platforms

**Files:**
- Modify: `Sources/ClaudeRelayClient/Views/ActivityDot.swift`
- Modify: `ClaudeRelayApp/Views/SessionSidebarView.swift`
- Modify: `ClaudeRelayMac/Views/SessionSidebarView.swift`
- Test: `Tests/ClaudeRelayClientTests/ActivityDotTests.swift` (create)

**Interfaces:**
- Consumes: `AgentDetectedState` (Task 1); `SharedSessionCoordinator.agentState(for:)`, `title(for:)`, `isUnseen(_:)` (Task 5).
- Produces: `ActivityDot(activity:agentId:agentState:seen:size:)` with `agentState: AgentDetectedState? = nil` and `seen: Bool = true` defaulted so all existing call sites (StatusBarView, attach sheets) keep compiling and render legacy behavior when `agentState` is nil.

> **Color map (from herdr `status.rs` `state_dot`/`state_label_color`, adapted to SwiftUI):** blocked → red (blink); working → agent color; done (idle + unseen) → teal; idle (seen) → green; unknown → gray. When `agentState` is nil, fall back to the existing `ActivityState`-driven color so servers without Phase 2 look unchanged.

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelayClientTests/ActivityDotTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

final class ActivityDotTests: XCTestCase {

    func testEquatableIncludesAgentStateAndSeen() {
        let a = ActivityDot(activity: .agentIdle, agentId: "claude", agentState: .blocked, seen: false)
        let b = ActivityDot(activity: .agentIdle, agentId: "claude", agentState: .blocked, seen: false)
        let c = ActivityDot(activity: .agentIdle, agentId: "claude", agentState: .idle, seen: false)
        let d = ActivityDot(activity: .agentIdle, agentId: "claude", agentState: .blocked, seen: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c, "different agentState must not be equal")
        XCTAssertNotEqual(a, d, "different seen must not be equal")
    }

    func testDefaultsPreserveLegacyConstruction() {
        // The existing 3-arg call site must still compile and be seen/nil.
        let dot = ActivityDot(activity: .agentActive, agentId: "codex")
        XCTAssertNil(dot.agentState)
        XCTAssertTrue(dot.seen)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ActivityDotTests`
Expected: FAIL — `ActivityDot` has no `agentState`/`seen` members.

- [ ] **Step 3: Extend `ActivityDot`**

Replace `Sources/ClaudeRelayClient/Views/ActivityDot.swift` with:

```swift
import SwiftUI
import ClaudeRelayKit

/// Small colored dot visualizing a session's state. When Phase-2 `agentState`
/// is present it drives the color/blink (herdr parity); otherwise the dot
/// falls back to the legacy `ActivityState`-based rendering so older servers
/// look unchanged.
///
/// Conforms to `Equatable` so SwiftUI can short-circuit redraws inside
/// loops such as `ForEach` and `TimelineView`.
public struct ActivityDot: View, Equatable {
    public let activity: ActivityState
    public var agentId: String?
    public var agentState: AgentDetectedState?
    public var seen: Bool
    public var size: CGFloat

    public init(
        activity: ActivityState,
        agentId: String? = nil,
        agentState: AgentDetectedState? = nil,
        seen: Bool = true,
        size: CGFloat = 8
    ) {
        self.activity = activity
        self.agentId = agentId
        self.agentState = agentState
        self.seen = seen
        self.size = size
    }

    @State private var blinkOpacity: Double = 1.0

    /// Whether the dot should pulse: a blocked agent (needs attention) or,
    /// in legacy mode, an agent awaiting input.
    private var shouldBlink: Bool {
        if let agentState { return agentState == .blocked }
        return activity == .agentIdle
    }

    private var color: Color {
        if let agentState {
            switch agentState {
            case .blocked: return .red
            case .working: return AgentColorPalette.color(for: agentId)
            case .idle:    return seen ? .green : .teal
            case .unknown: return .gray
            }
        }
        // Legacy fallback (no Phase-2 state reported).
        switch activity {
        case .active, .idle: return .green
        case .agentActive, .agentIdle: return AgentColorPalette.color(for: agentId)
        }
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .fixedSize()
            .opacity(shouldBlink ? blinkOpacity : 1.0)
            .onChange(of: shouldBlink) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                } else {
                    withAnimation(.default) { blinkOpacity = 1.0 }
                }
            }
            .onAppear {
                if shouldBlink {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                }
            }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.activity == rhs.activity
            && lhs.agentId == rhs.agentId
            && lhs.agentState == rhs.agentState
            && lhs.seen == rhs.seen
            && lhs.size == rhs.size
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ActivityDotTests`
Expected: PASS (2 tests). `StatusBarView.swift:20` and the attach sheets keep compiling because `agentState`/`seen` default to `nil`/`true`.

- [ ] **Step 5: Wire the iOS sidebar to the new state + title**

In `ClaudeRelayApp/Views/SessionSidebarView.swift`:

Pass the new fields into `SessionRow` at the call site (change lines 44-58's argument list) — add `agentState`, `seen`, and `title` after `agentId`:
```swift
                        SessionRow(
                            session: session,
                            name: coordinator.name(for: session.id),
                            shortId: String(session.id.uuidString.prefix(8)),
                            isActive: session.id == coordinator.activeSessionId,
                            activity: coordinator.activityState(for: session.id),
                            agentId: agentId(for: session.id),
                            agentState: coordinator.agentState(for: session.id),
                            seen: !coordinator.isUnseen(session.id),
                            title: coordinator.title(for: session.id),
                            onRename: { newName in
                                coordinator.setName(newName, for: session.id)
                            },
                            onShareQR: {
                                qrSessionId = session.id
                                showQRSheet = true
                            }
                        )
```

Add the three stored props to `SessionRow` (after line 113's `let agentId: String?`):
```swift
    let agentState: AgentDetectedState?
    let seen: Bool
    let title: String?
```

Update the `ActivityDot` inside `SessionRow.body` (line 122):
```swift
            ActivityDot(activity: activity, agentId: agentId, agentState: agentState, seen: seen, size: 8)
```

Add a title line under the name (inside the name `VStack`, after the `shortId` Text at line 132). Replace the inner VStack (lines 124-133) with:
```swift
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
```

- [ ] **Step 6: Wire the macOS sidebar to the new state + title**

In `ClaudeRelayMac/Views/SessionSidebarView.swift`:

At the `SessionRow` call site (lines 24-30), add the new args:
```swift
                        SessionRow(
                            name: coordinator.name(for: session.id),
                            shortId: String(session.id.uuidString.prefix(8)),
                            activity: coordinator.activityState(for: session.id),
                            agentId: coordinator.activeAgent(for: session.id),
                            agentState: coordinator.agentState(for: session.id),
                            seen: !coordinator.isUnseen(session.id),
                            title: coordinator.title(for: session.id),
                            createdAt: session.createdAt
                        )
```

Add stored props to `SessionRow` (after line 117's `let agentId: String?`):
```swift
    let agentState: AgentDetectedState?
    let seen: Bool
    let title: String?
```

Update the row body (lines 120-133) — dot + title line:
```swift
    var body: some View {
        HStack(spacing: 8) {
            ActivityDot(activity: activity, agentId: agentId, agentState: agentState, seen: seen, size: 6)
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
                        .monospaced()
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
```

- [ ] **Step 7: Build the SPM client + confirm apps compile**

Run: `swift build`
Expected: builds clean. The app targets are XcodeGen-globbed `.swift` files; no `project.yml` change was made, so no `xcodegen` run is required — the edited sidebar files are picked up on the next Xcode build. Open `ClaudeRelay.xcodeproj` and Cmd+B (iOS) and build `ClaudeRelayMac` to confirm both apps compile against the widened `ActivityDot` and coordinator accessors.

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeRelayClient/Views/ActivityDot.swift ClaudeRelayApp/Views/SessionSidebarView.swift ClaudeRelayMac/Views/SessionSidebarView.swift Tests/ClaudeRelayClientTests/ActivityDotTests.swift
git commit -m "feat(apps): richer sidebar with agent state + window title

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 9: Final full-suite gate**

Run: `swift build && swift test`
Expected: entire suite PASSES. This is the Phase 2 completion gate.

---

## Notes for the implementer

- **Order matters:** Tasks 1→5 are strictly sequential (each widens a type the next consumes). Task 4 must land in one commit — the callback type change ripples through four files and leaves the tree uncompilable if split.
- **herdr fidelity:** the manifest JSON is a faithful translation of the three TOMLs as they existed at the versions pinned in this plan (`claude` 2026.07.13.1, `codex` 2026.07.18.1, `opencode` 2026.06.10.1). If herdr updates its rules upstream, re-translate the TOMLs rather than hand-editing the JSON.
- **What Phase 2 deliberately omits (YAGNI):** herdr's `stable_visible_signal_refresh` (800 ms re-publish for persistent blockers) and the `detection_content_seq` scan-skip optimization. Code Relay's poll cadence (1 s attached / 5 s detached) already bounds detection cost; add these only if profiling shows a need.
- **Regex escaping is the #1 translation hazard:** in JSON, `\s` must be written `\\s`, and a Unicode escape herdr writes as `\x{2800}` becomes `⠀` in a JSON string literal (JSON's own `\u` form) — NOT `\\x{2800}`. The `AgentStateDetectorTests` spinner/idle tests exist precisely to catch a botched escape.
