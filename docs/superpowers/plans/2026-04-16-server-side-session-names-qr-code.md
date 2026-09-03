# Server-Side Session Names + QR Code Session Sharing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist session names on the server with real-time broadcast sync, and add QR code generation/scanning for cross-device session attachment.

**Architecture:** Two coordinated features built bottom-up: wire protocol (ClaudeRelayKit) → server (ClaudeRelayServer) → client library (ClaudeRelayClient) → iOS app (ClaudeRelayApp). The `name` field is added to `SessionInfo`, a `sessionRename` client message and `sessionRenamed` server broadcast are added to the wire protocol, and the server broadcasts renames via the existing activity observer infrastructure. The QR code feature uses CoreImage for generation and AVFoundation for scanning, with a `coderelay://` URL scheme for deep linking.

**Tech Stack:** Swift 5.9, SwiftUI, NIO, CoreImage (QR generation), AVFoundation (QR scanning), XcodeGen

---

## File Structure

### Modified files
| File | Responsibility |
|------|---------------|
| `Sources/ClaudeRelayKit/Models/SessionInfo.swift` | Add `name: String?` field |
| `Sources/ClaudeRelayKit/Protocol/ClientMessage.swift` | Add `name` to `sessionCreate`, add `sessionRename` case |
| `Sources/ClaudeRelayKit/Protocol/ServerMessage.swift` | Add `sessionRenamed` case |
| `Sources/ClaudeRelayServer/Actors/SessionManager.swift` | Accept name in create, add `renameSession`, broadcast renames |
| `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift` | Route `sessionRename` message |
| `Sources/ClaudeRelayClient/SessionController.swift` | Add name param to create, add `renameSession` method |
| `Sources/ClaudeRelayClient/RelayConnection.swift` | Route `sessionRenamed` callback |
| `ClaudeRelayApp/ViewModels/SessionCoordinator.swift` | Sync names with server, handle rename broadcast |
| `ClaudeRelayApp/Views/ActiveTerminalView.swift` | Add QR button + overlay |
| `ClaudeRelayApp/Views/SessionSidebarView.swift` | Show server names in attach sheet, add Scan QR Code button |
| `ClaudeRelayApp/ClaudeRelayApp.swift` | Handle `onOpenURL` for deep linking |
| `project.yml` | Add URL scheme + camera permission |
| `Tests/ClaudeRelayKitTests/ProtocolMessageTests.swift` | Tests for new message types |
| `Tests/ClaudeRelayServerTests/SessionManagerTests.swift` | Tests for name create/rename/broadcast |

### New files
| File | Responsibility |
|------|---------------|
| `ClaudeRelayApp/Views/QRScannerView.swift` | UIViewRepresentable wrapping AVCaptureSession for QR scanning |

---

## Task 1: Add `name` field to SessionInfo

**Files:**
- Modify: `Sources/ClaudeRelayKit/Models/SessionInfo.swift`

- [ ] **Step 1: Add `name` property and update init**

In `Sources/ClaudeRelayKit/Models/SessionInfo.swift`, replace the entire struct with:

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

    public init(
        id: UUID,
        name: String? = nil,
        state: SessionState,
        tokenId: String,
        createdAt: Date,
        cols: UInt16,
        rows: UInt16,
        activity: ActivityState? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.tokenId = tokenId
        self.createdAt = createdAt
        self.cols = cols
        self.rows = rows
        self.activity = activity
    }
}
```

The `name` parameter defaults to `nil` so all existing call sites compile without changes. The field position (after `id`, before `state`) keeps it logically grouped.

- [ ] **Step 2: Build to verify all existing call sites compile**

Run: `swift build 2>&1 | head -30`
Expected: Build succeeds — all existing `SessionInfo(id:, state:, ...)` calls use the default `nil` for name.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelayKit/Models/SessionInfo.swift
git commit -m "feat(kit): add name field to SessionInfo"
```

---

## Task 2: Add `sessionCreate(name:)` and `sessionRename` to ClientMessage

**Files:**
- Modify: `Sources/ClaudeRelayKit/Protocol/ClientMessage.swift`
- Test: `Tests/ClaudeRelayKitTests/ProtocolMessageTests.swift`

- [ ] **Step 1: Write failing tests for new message types**

Add these tests at the end of `ProtocolMessageTests.swift` (before the closing `}`):

```swift
// MARK: - sessionCreate with name

func testSessionCreateWithNameEncoding() throws {
    let msg = ClientMessage.sessionCreate(name: "Rhaegar")
    let envelope = MessageEnvelope.client(msg)
    let data = try encoder.encode(envelope)
    let obj = try jsonObject(data)

    XCTAssertEqual(obj["type"] as? String, "session_create")
    let payload = obj["payload"] as? [String: Any]
    XCTAssertEqual(payload?["name"] as? String, "Rhaegar")
}

func testSessionCreateWithoutNameEncoding() throws {
    let msg = ClientMessage.sessionCreate(name: nil)
    let envelope = MessageEnvelope.client(msg)
    let data = try encoder.encode(envelope)
    let obj = try jsonObject(data)

    XCTAssertEqual(obj["type"] as? String, "session_create")
}

func testSessionCreateWithNameRoundTrip() throws {
    let original = ClientMessage.sessionCreate(name: "Tyrion")
    let envelope = MessageEnvelope.client(original)
    let data = try encoder.encode(envelope)
    let decoded = try decoder.decode(MessageEnvelope.self, from: data)
    guard case .client(let roundTripped) = decoded else {
        XCTFail("Expected .client envelope"); return
    }
    XCTAssertEqual(original, roundTripped)
}

func testSessionCreateWithoutNameRoundTrip() throws {
    let original = ClientMessage.sessionCreate(name: nil)
    let envelope = MessageEnvelope.client(original)
    let data = try encoder.encode(envelope)
    let decoded = try decoder.decode(MessageEnvelope.self, from: data)
    guard case .client(let roundTripped) = decoded else {
        XCTFail("Expected .client envelope"); return
    }
    XCTAssertEqual(original, roundTripped)
}

// MARK: - sessionRename

func testSessionRenameEncoding() throws {
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let msg = ClientMessage.sessionRename(sessionId: id, name: "Daenerys")
    let envelope = MessageEnvelope.client(msg)
    let data = try encoder.encode(envelope)
    let obj = try jsonObject(data)

    XCTAssertEqual(obj["type"] as? String, "session_rename")
    let payload = obj["payload"] as? [String: Any]
    XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    XCTAssertEqual(payload?["name"] as? String, "Daenerys")
}

func testSessionRenameRoundTrip() throws {
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let original = ClientMessage.sessionRename(sessionId: id, name: "Sansa")
    let envelope = MessageEnvelope.client(original)
    let data = try encoder.encode(envelope)
    let decoded = try decoder.decode(MessageEnvelope.self, from: data)
    guard case .client(let roundTripped) = decoded else {
        XCTFail("Expected .client envelope"); return
    }
    XCTAssertEqual(original, roundTripped)
}

func testSessionRenameFieldVerification() throws {
    let id = "12345678-1234-1234-1234-123456789ABC"
    let json = #"{"type":"session_rename","payload":{"sessionId":"\#(id)","name":"Arya"}}"#
    let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
    guard case .client(.sessionRename(let sessionId, let name)) = envelope else {
        XCTFail("Expected sessionRename"); return
    }
    XCTAssertEqual(sessionId.uuidString, id)
    XCTAssertEqual(name, "Arya")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProtocolMessageTests 2>&1 | tail -20`
Expected: Compilation errors — `sessionCreate` doesn't accept `name`, `sessionRename` doesn't exist.

- [ ] **Step 3: Implement ClientMessage changes**

In `Sources/ClaudeRelayKit/Protocol/ClientMessage.swift`:

**a)** Change the enum cases:

Replace:
```swift
    case sessionCreate
```
With:
```swift
    case sessionCreate(name: String? = nil)
```

Add after `case sessionList`:
```swift
    case sessionRename(sessionId: UUID, name: String)
```

Note: No change needed for `case sessionListAll` or later cases.

**b)** Update `typeString`:

Replace:
```swift
        case .sessionCreate:  return "session_create"
```
With:
```swift
        case .sessionCreate:     return "session_create"
```

Add after the `sessionListAll` case:
```swift
        case .sessionRename:     return "session_rename"
```

**c)** Update `allTypeStrings` — add `"session_rename"`:

Replace:
```swift
    static let allTypeStrings: Set<String> = [
        "auth_request", "session_create", "session_attach",
        "session_resume", "session_detach", "session_terminate", "session_list", "session_list_all", "resize", "ping"
    ]
```
With:
```swift
    static let allTypeStrings: Set<String> = [
        "auth_request", "session_create", "session_attach",
        "session_resume", "session_detach", "session_terminate", "session_list", "session_list_all",
        "session_rename", "resize", "ping"
    ]
```

**d)** Update `PayloadCodingKeys` — add `name`:

Replace:
```swift
    private enum PayloadCodingKeys: String, CodingKey {
        case token, sessionId, cols, rows
    }
```
With:
```swift
    private enum PayloadCodingKeys: String, CodingKey {
        case token, sessionId, cols, rows, name
    }
```

**e)** Update `encodePayload`:

Replace:
```swift
        case .sessionCreate:
            break
```
With:
```swift
        case .sessionCreate(let name):
            try container.encodeIfPresent(name, forKey: .name)
```

Add after the `sessionListAll` case:
```swift
        case .sessionRename(let sessionId, let name):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(name, forKey: .name)
```

**f)** Update `decode(typeString:from:)`:

Replace:
```swift
        case "session_create":
            return .sessionCreate
```
With:
```swift
        case "session_create":
            let name = try container.decodeIfPresent(String.self, forKey: .name)
            return .sessionCreate(name: name)
```

Add after the `"session_list_all"` case:
```swift
        case "session_rename":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let name = try container.decode(String.self, forKey: .name)
            return .sessionRename(sessionId: sessionId, name: name)
```

- [ ] **Step 4: Update existing tests that reference `.sessionCreate`**

In `ProtocolMessageTests.swift`, update `testSessionCreateEncoding`:

Replace:
```swift
    func testSessionCreateEncoding() throws {
        let msg = ClientMessage.sessionCreate
```
With:
```swift
    func testSessionCreateEncoding() throws {
        let msg = ClientMessage.sessionCreate()
```

In `testClientMessageRoundTrips`, update the array:

Replace:
```swift
            .sessionCreate,
```
With:
```swift
            .sessionCreate(),
```

In `testClientMessageEquatable`:

Replace:
```swift
        XCTAssertEqual(ClientMessage.sessionCreate, ClientMessage.sessionCreate)
```
With:
```swift
        XCTAssertEqual(ClientMessage.sessionCreate(), ClientMessage.sessionCreate())
```

Replace:
```swift
        XCTAssertNotEqual(ClientMessage.ping, ClientMessage.sessionCreate)
```
With:
```swift
        XCTAssertNotEqual(ClientMessage.ping, ClientMessage.sessionCreate())
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ProtocolMessageTests 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelayKit/Protocol/ClientMessage.swift Tests/ClaudeRelayKitTests/ProtocolMessageTests.swift
git commit -m "feat(kit): add name to sessionCreate, add sessionRename message"
```

---

## Task 3: Add `sessionRenamed` to ServerMessage

**Files:**
- Modify: `Sources/ClaudeRelayKit/Protocol/ServerMessage.swift`
- Test: `Tests/ClaudeRelayKitTests/ProtocolMessageTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `ProtocolMessageTests.swift`:

```swift
// MARK: - sessionRenamed

func testSessionRenamedEncoding() throws {
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let msg = ServerMessage.sessionRenamed(sessionId: id, name: "Cersei")
    let envelope = MessageEnvelope.server(msg)
    let data = try encoder.encode(envelope)
    let obj = try jsonObject(data)

    XCTAssertEqual(obj["type"] as? String, "session_renamed")
    let payload = obj["payload"] as? [String: Any]
    XCTAssertEqual(payload?["sessionId"] as? String, id.uuidString)
    XCTAssertEqual(payload?["name"] as? String, "Cersei")
}

func testSessionRenamedRoundTrip() throws {
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let original = ServerMessage.sessionRenamed(sessionId: id, name: "Jon Snow")
    let envelope = MessageEnvelope.server(original)
    let data = try encoder.encode(envelope)
    let decoded = try decoder.decode(MessageEnvelope.self, from: data)
    guard case .server(let roundTripped) = decoded else {
        XCTFail("Expected .server envelope"); return
    }
    XCTAssertEqual(original, roundTripped)
}

func testSessionRenamedFieldVerification() throws {
    let id = "12345678-1234-1234-1234-123456789ABC"
    let json = #"{"type":"session_renamed","payload":{"sessionId":"\#(id)","name":"Bran"}}"#
    let envelope = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
    guard case .server(.sessionRenamed(let sessionId, let name)) = envelope else {
        XCTFail("Expected sessionRenamed"); return
    }
    XCTAssertEqual(sessionId.uuidString, id)
    XCTAssertEqual(name, "Bran")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProtocolMessageTests 2>&1 | tail -10`
Expected: Compilation errors — `sessionRenamed` doesn't exist on `ServerMessage`.

- [ ] **Step 3: Implement ServerMessage changes**

In `Sources/ClaudeRelayKit/Protocol/ServerMessage.swift`:

**a)** Add the new case after `sessionStolen`:

```swift
    case sessionRenamed(sessionId: UUID, name: String)
```

**b)** Add `typeString` after `sessionStolen`:

```swift
        case .sessionRenamed:      return "session_renamed"
```

**c)** Add `"session_renamed"` to `allTypeStrings`:

Replace:
```swift
    static let allTypeStrings: Set<String> = [
        "auth_success", "auth_failure", "session_created", "session_attached",
        "session_resumed", "session_detached", "session_terminated",
        "session_expired", "session_state", "session_activity", "session_stolen", "session_list_result", "session_list_all_result", "resize_ack", "pong", "error"
    ]
```
With:
```swift
    static let allTypeStrings: Set<String> = [
        "auth_success", "auth_failure", "session_created", "session_attached",
        "session_resumed", "session_detached", "session_terminated",
        "session_expired", "session_state", "session_activity", "session_stolen",
        "session_renamed", "session_list_result", "session_list_all_result",
        "resize_ack", "pong", "error"
    ]
```

**d)** Add `name` to `PayloadCodingKeys`:

Replace:
```swift
    private enum PayloadCodingKeys: String, CodingKey {
        case reason, sessionId, cols, rows, state, code, message, sessions, activity
    }
```
With:
```swift
    private enum PayloadCodingKeys: String, CodingKey {
        case reason, sessionId, cols, rows, state, code, message, sessions, activity, name
    }
```

**e)** Add `encodePayload` case after `sessionStolen`:

```swift
        case .sessionRenamed(let sessionId, let name):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(name, forKey: .name)
```

**f)** Add `decode` case after `"session_stolen"`:

```swift
        case "session_renamed":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let name = try container.decode(String.self, forKey: .name)
            return .sessionRenamed(sessionId: sessionId, name: name)
```

- [ ] **Step 4: Add sessionRenamed to the round-trip test array**

In `testServerMessageRoundTrips`, add to the `messages` array (after `.sessionStolen`):

```swift
            .sessionRenamed(sessionId: id, name: "Varys"),
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ProtocolMessageTests 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelayKit/Protocol/ServerMessage.swift Tests/ClaudeRelayKitTests/ProtocolMessageTests.swift
git commit -m "feat(kit): add sessionRenamed server broadcast message"
```

---

## Task 4: Update SessionManager to store and broadcast names

**Files:**
- Modify: `Sources/ClaudeRelayServer/Actors/SessionManager.swift`
- Test: `Tests/ClaudeRelayServerTests/SessionManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `SessionManagerTests.swift`:

```swift
// MARK: - Session Names

func testCreateSessionWithName() async throws {
    let (_, tokenInfo) = try await createTestToken()
    let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
        MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
    })

    let session = try await manager.createSession(tokenId: tokenInfo.id, name: "Rhaegar")

    XCTAssertEqual(session.name, "Rhaegar")
    let inspected = try await manager.inspectSession(id: session.id)
    XCTAssertEqual(inspected.name, "Rhaegar")
}

func testCreateSessionWithoutName() async throws {
    let (_, tokenInfo) = try await createTestToken()
    let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
        MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
    })

    let session = try await manager.createSession(tokenId: tokenInfo.id)

    XCTAssertNil(session.name)
}

func testRenameSession() async throws {
    let (_, tokenInfo) = try await createTestToken()
    let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
        MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
    })

    let session = try await manager.createSession(tokenId: tokenInfo.id, name: "Tyrion")
    try await manager.renameSession(id: session.id, tokenId: tokenInfo.id, name: "Jaime")

    let inspected = try await manager.inspectSession(id: session.id)
    XCTAssertEqual(inspected.name, "Jaime")
}

func testRenameSessionOwnershipViolation() async throws {
    let (_, tokenA) = try await createTestToken()
    let (_, tokenB) = try await tokenStore.create(label: "other")
    let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
        MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
    })

    let session = try await manager.createSession(tokenId: tokenA.id, name: "Tyrion")

    do {
        try await manager.renameSession(id: session.id, tokenId: tokenB.id, name: "Stolen")
        XCTFail("Expected ownership violation")
    } catch let error as SessionError {
        if case .ownershipViolation = error {
            // expected
        } else {
            XCTFail("Expected ownershipViolation, got \(error)")
        }
    }
}

func testRenameSessionBroadcastsToObservers() async throws {
    let (_, tokenInfo) = try await createTestToken()
    let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
        MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
    })

    let session = try await manager.createSession(tokenId: tokenInfo.id, name: "Old")

    let expectation = XCTestExpectation(description: "rename callback")
    var receivedName: String?
    var receivedSessionId: UUID?
    let observerId = await manager.addRenameObserver(tokenId: tokenInfo.id) { sessionId, name in
        receivedSessionId = sessionId
        receivedName = name
        expectation.fulfill()
    }

    try await manager.renameSession(id: session.id, tokenId: tokenInfo.id, name: "New")

    await fulfillment(of: [expectation], timeout: 1.0)
    XCTAssertEqual(receivedSessionId, session.id)
    XCTAssertEqual(receivedName, "New")
    await manager.removeRenameObserver(id: observerId)
}

func testListSessionsIncludesName() async throws {
    let (_, tokenInfo) = try await createTestToken()
    let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
        MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
    })

    _ = try await manager.createSession(tokenId: tokenInfo.id, name: "Named")
    _ = try await manager.createSession(tokenId: tokenInfo.id)

    let list = await manager.listSessionsForToken(tokenId: tokenInfo.id)
    let names = list.map { $0.name }
    XCTAssertTrue(names.contains("Named"))
    XCTAssertTrue(names.contains(nil))
}

func testAttachSessionPreservesName() async throws {
    let (_, tokenA) = try await createTestToken()
    let (_, tokenB) = try await tokenStore.create(label: "other")
    let manager = SessionManager(config: config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
        MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
    })

    let session = try await manager.createSession(tokenId: tokenA.id, name: "Rhaegar")
    let (attachedInfo, _) = try await manager.attachSession(id: session.id, tokenId: tokenB.id)

    XCTAssertEqual(attachedInfo.name, "Rhaegar")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionManagerTests 2>&1 | tail -20`
Expected: Compilation errors — `createSession` doesn't accept `name`, `renameSession` and `addRenameObserver` don't exist.

- [ ] **Step 3: Implement SessionManager changes**

In `Sources/ClaudeRelayServer/Actors/SessionManager.swift`:

**a)** Add rename observer types after the steal observer declarations (around line 26):

```swift
    public typealias RenameObserver = @Sendable (UUID, String) -> Void
    private var renameObservers: [UUID: (tokenId: String, callback: RenameObserver)] = [:]
```

**b)** Update `createSession` signature and body to accept `name`:

Replace the signature:
```swift
    public func createSession(
        tokenId: String,
        cols: UInt16 = 80,
        rows: UInt16 = 24
    ) async throws -> SessionInfo {
```
With:
```swift
    public func createSession(
        tokenId: String,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        name: String? = nil
    ) async throws -> SessionInfo {
```

Replace the `startingInfo` creation:
```swift
        let startingInfo = SessionInfo(
            id: id,
            state: .starting,
            tokenId: tokenId,
            createdAt: now,
            cols: cols,
            rows: rows
        )
```
With:
```swift
        let startingInfo = SessionInfo(
            id: id,
            name: name,
            state: .starting,
            tokenId: tokenId,
            createdAt: now,
            cols: cols,
            rows: rows
        )
```

Replace the `activeInfo` creation:
```swift
        let activeInfo = SessionInfo(
            id: id,
            state: .activeAttached,
            tokenId: tokenId,
            createdAt: now,
            cols: cols,
            rows: rows
        )
```
With:
```swift
        let activeInfo = SessionInfo(
            id: id,
            name: name,
            state: .activeAttached,
            tokenId: tokenId,
            createdAt: now,
            cols: cols,
            rows: rows
        )
```

**c)** Add `renameSession` method. Place it after `terminateSession` (before `listSessions`):

```swift
    /// Rename a session. Validates ownership and broadcasts to observers.
    public func renameSession(id: UUID, tokenId: String, name: String) throws {
        guard var managed = sessions[id] else {
            throw SessionError.notFound(id)
        }
        guard managed.info.tokenId == tokenId else {
            throw SessionError.ownershipViolation
        }

        let info = managed.info
        managed.info = SessionInfo(
            id: info.id,
            name: name,
            state: info.state,
            tokenId: info.tokenId,
            createdAt: info.createdAt,
            cols: info.cols,
            rows: info.rows,
            activity: info.activity
        )
        sessions[id] = managed

        // Broadcast rename to all observers for this token
        for (_, observer) in renameObservers where observer.tokenId == tokenId {
            observer.callback(id, name)
        }
    }
```

**d)** Add rename observer management methods. Place after the steal observer section:

```swift
    // MARK: - Rename Observers

    @discardableResult
    public func addRenameObserver(
        tokenId: String,
        callback: @escaping RenameObserver
    ) -> UUID {
        let observerId = UUID()
        renameObservers[observerId] = (tokenId: tokenId, callback: callback)
        return observerId
    }

    public func removeRenameObserver(id: UUID) {
        renameObservers.removeValue(forKey: id)
    }
```

**e)** Preserve `name` in all methods that reconstruct `SessionInfo`. In `attachSession`, update the `newInfo` construction:

Replace:
```swift
        let newInfo = SessionInfo(
            id: managed.info.id,
            state: newState,
            tokenId: tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```
With:
```swift
        let newInfo = SessionInfo(
            id: managed.info.id,
            name: managed.info.name,
            state: newState,
            tokenId: tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```

In `detachSession`, update the `newInfo` construction:

Replace:
```swift
        let newInfo = SessionInfo(
            id: managed.info.id,
            state: newState,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```
With:
```swift
        let newInfo = SessionInfo(
            id: managed.info.id,
            name: managed.info.name,
            state: newState,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```

In `resumeSession`, update **both** `SessionInfo` constructions (the intermediate detach and the resuming/attached ones):

The first one (detach fallback, around line 216):
Replace:
```swift
            managed.info = SessionInfo(
                id: managed.info.id, state: .activeDetached,
                tokenId: managed.info.tokenId, createdAt: managed.info.createdAt,
                cols: managed.info.cols, rows: managed.info.rows
            )
```
With:
```swift
            managed.info = SessionInfo(
                id: managed.info.id, name: managed.info.name, state: .activeDetached,
                tokenId: managed.info.tokenId, createdAt: managed.info.createdAt,
                cols: managed.info.cols, rows: managed.info.rows
            )
```

The second one (resumingInfo):
Replace:
```swift
        let resumingInfo = SessionInfo(
            id: managed.info.id,
            state: .resuming,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```
With:
```swift
        let resumingInfo = SessionInfo(
            id: managed.info.id,
            name: managed.info.name,
            state: .resuming,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```

The third one (attachedInfo):
Replace:
```swift
        let attachedInfo = SessionInfo(
            id: managed.info.id,
            state: .activeAttached,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```
With:
```swift
        let attachedInfo = SessionInfo(
            id: managed.info.id,
            name: managed.info.name,
            state: .activeAttached,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```

In `terminateSession`:
Replace:
```swift
        let newInfo = SessionInfo(
            id: managed.info.id,
            state: newState,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```
With:
```swift
        let newInfo = SessionInfo(
            id: managed.info.id,
            name: managed.info.name,
            state: newState,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```

In `listSessionsForToken`, update the enriched info:
Replace:
```swift
                info = SessionInfo(
                    id: info.id,
                    state: info.state,
                    tokenId: info.tokenId,
                    createdAt: info.createdAt,
                    cols: info.cols,
                    rows: info.rows,
                    activity: activity
                )
```
With:
```swift
                info = SessionInfo(
                    id: info.id,
                    name: info.name,
                    state: info.state,
                    tokenId: info.tokenId,
                    createdAt: info.createdAt,
                    cols: info.cols,
                    rows: info.rows,
                    activity: activity
                )
```

In `listAllSessions`, same change:
Replace:
```swift
                info = SessionInfo(
                    id: info.id,
                    state: info.state,
                    tokenId: info.tokenId,
                    createdAt: info.createdAt,
                    cols: info.cols,
                    rows: info.rows,
                    activity: activity
                )
```
With:
```swift
                info = SessionInfo(
                    id: info.id,
                    name: info.name,
                    state: info.state,
                    tokenId: info.tokenId,
                    createdAt: info.createdAt,
                    cols: info.cols,
                    rows: info.rows,
                    activity: activity
                )
```

In `shutdown`:
Replace:
```swift
            updated.info = SessionInfo(
                id: managed.info.id,
                state: .terminated,
                tokenId: managed.info.tokenId,
                createdAt: managed.info.createdAt,
                cols: managed.info.cols,
                rows: managed.info.rows
            )
```
With:
```swift
            updated.info = SessionInfo(
                id: managed.info.id,
                name: managed.info.name,
                state: .terminated,
                tokenId: managed.info.tokenId,
                createdAt: managed.info.createdAt,
                cols: managed.info.cols,
                rows: managed.info.rows
            )
```

In `handlePTYExit`:
Replace:
```swift
        let newInfo = SessionInfo(
            id: managed.info.id,
            state: .exited,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```
With:
```swift
        let newInfo = SessionInfo(
            id: managed.info.id,
            name: managed.info.name,
            state: .exited,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```

In `handleDetachTimeout`:
Replace:
```swift
        let newInfo = SessionInfo(
            id: managed.info.id,
            state: .expired,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```
With:
```swift
        let newInfo = SessionInfo(
            id: managed.info.id,
            name: managed.info.name,
            state: .expired,
            tokenId: managed.info.tokenId,
            createdAt: managed.info.createdAt,
            cols: managed.info.cols,
            rows: managed.info.rows
        )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SessionManagerTests 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayServer/Actors/SessionManager.swift Tests/ClaudeRelayServerTests/SessionManagerTests.swift
git commit -m "feat(server): store session names, add renameSession with broadcast"
```

---

## Task 5: Route `sessionRename` in RelayMessageHandler

**Files:**
- Modify: `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`

- [ ] **Step 1: Add `sessionRename` case to `handleAuthenticatedMessage`**

In `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`, in `handleAuthenticatedMessage`:

Replace:
```swift
        case .sessionCreate:
            handleSessionCreate(context: context)
```
With:
```swift
        case .sessionCreate(let name):
            handleSessionCreate(name: name, context: context)
```

Add after the `sessionListAll` case:
```swift
        case .sessionRename(let sessionId, let name):
            handleSessionRename(sessionId: sessionId, name: name, context: context)
```

- [ ] **Step 2: Update `handleSessionCreate` to pass name through**

Replace the method signature:
```swift
    private func handleSessionCreate(context: ChannelHandlerContext) {
```
With:
```swift
    private func handleSessionCreate(name: String?, context: ChannelHandlerContext) {
```

Replace the `createSession` call:
```swift
                let info = try await sessionManager.createSession(tokenId: tokenId)
```
With:
```swift
                let info = try await sessionManager.createSession(tokenId: tokenId, name: name)
```

- [ ] **Step 3: Add `handleSessionRename` method**

Add after `handleSessionListAll`:

```swift
    // MARK: - Session Rename

    private func handleSessionRename(sessionId: UUID, name: String, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let sessionManager = self.sessionManager
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            do {
                try await sessionManager.renameSession(id: sessionId, tokenId: tokenId, name: name)
                RelayLogger.log(category: "session", "Session renamed: \(sessionId) -> \(name)")
            } catch {
                ctx.value.eventLoop.execute {
                    self?.sendServerMessage(.error(code: 404, message: "Rename failed: \(error)"), context: ctx.value)
                }
            }
        }
    }
```

Note: No response message is sent on success — the rename observer (wired up in `handleAuth`) broadcasts `sessionRenamed` to all connections.

- [ ] **Step 4: Subscribe to rename observer in `handleAuth`**

In the `handleAuth` method, inside the `Task` that registers observers (after the `addStealObserver` call, around line 196), add the rename observer subscription:

After:
```swift
                        let stealId = await manager.addStealObserver(tokenId: info.id) { [weak self] sessionId in
                            observerCtx.value.eventLoop.execute {
                                guard let self = self else { return }
                                // Only notify if this connection is the one that lost the session.
                                if self.attachedSessionId == sessionId {
                                    self.attachedSessionId = nil
                                    self.attachedPTY = nil
                                    self.sendServerMessage(.sessionStolen(sessionId: sessionId), context: observerCtx.value)
                                }
                            }
                        }
```

Add:
```swift
                        let renameId = await manager.addRenameObserver(tokenId: info.id) { [weak self] sessionId, name in
                            observerCtx.value.eventLoop.execute {
                                self?.sendServerMessage(.sessionRenamed(sessionId: sessionId, name: name), context: observerCtx.value)
                            }
                        }
```

Update the eventLoop.execute block that stores observer IDs:

Replace:
```swift
                        observerCtx.value.eventLoop.execute {
                            self?.activityObserverId = observerId
                            self?.stealObserverId = stealId
                        }
```
With:
```swift
                        observerCtx.value.eventLoop.execute {
                            self?.activityObserverId = observerId
                            self?.stealObserverId = stealId
                            self?.renameObserverId = renameId
                        }
```

- [ ] **Step 5: Add `renameObserverId` property and cleanup**

Add the property after `stealObserverId`:
```swift
    private var renameObserverId: UUID?
```

In `cleanupSession`, add cleanup after the steal observer cleanup:

After:
```swift
        if let observerId = stealObserverId {
            let manager = sessionManager
            stealObserverId = nil
            Task {
                await manager.removeStealObserver(id: observerId)
            }
        }
```

Add:
```swift
        if let observerId = renameObserverId {
            let manager = sessionManager
            renameObserverId = nil
            Task {
                await manager.removeRenameObserver(id: observerId)
            }
        }
```

- [ ] **Step 6: Build and run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass — including existing integration tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift
git commit -m "feat(server): route sessionRename, subscribe to rename broadcasts"
```

---

## Task 6: Update client library (SessionController + RelayConnection)

**Files:**
- Modify: `Sources/ClaudeRelayClient/SessionController.swift`
- Modify: `Sources/ClaudeRelayClient/RelayConnection.swift`

- [ ] **Step 1: Add `onSessionRenamed` callback to RelayConnection**

In `Sources/ClaudeRelayClient/RelayConnection.swift`, add after the `onSessionStolen` property:

```swift
    /// Push callback: server renamed a session (another device renamed it).
    public var onSessionRenamed: ((UUID, String) -> Void)?
```

In the `handleWebSocketMessage` method, add a case to the push-routing switch (after `case .sessionStolen`):

```swift
                    case .sessionRenamed(let sessionId, let name):
                        onSessionRenamed?(sessionId, name)
```

- [ ] **Step 2: Update `SessionController.createSession` to accept name**

In `Sources/ClaudeRelayClient/SessionController.swift`:

Replace:
```swift
    @discardableResult
    public func createSession() async throws -> UUID {
        let response = try await sendAndWaitForResponse(.sessionCreate)
```
With:
```swift
    @discardableResult
    public func createSession(name: String? = nil) async throws -> UUID {
        let response = try await sendAndWaitForResponse(.sessionCreate(name: name))
```

- [ ] **Step 3: Add `renameSession` method**

Add after `listAllSessions`:

```swift
    /// Renames a session. Fire-and-forget — the server broadcasts the rename
    /// to all connections via `sessionRenamed`. No response expected.
    public func renameSession(id: UUID, name: String) async throws {
        try await connection.send(.sessionRename(sessionId: id, name: name))
    }
```

- [ ] **Step 4: Build to verify**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelayClient/SessionController.swift Sources/ClaudeRelayClient/RelayConnection.swift
git commit -m "feat(client): add session name support to SessionController + RelayConnection"
```

---

## Task 7: Update SessionCoordinator to sync names with server

**Files:**
- Modify: `ClaudeRelayApp/ViewModels/SessionCoordinator.swift`

- [ ] **Step 1: Wire up `onSessionRenamed` callback in init**

In the `init` method, after the `onSessionStolen` callback:

```swift
        connection.onSessionRenamed = { [weak self] sessionId, name in
            Task { @MainActor [weak self] in
                self?.handleSessionRenamed(sessionId: sessionId, name: name)
            }
        }
```

- [ ] **Step 2: Add `handleSessionRenamed` method**

Add after `handleSessionStolen`:

```swift
    /// Handle server broadcast: another connection renamed a session.
    private func handleSessionRenamed(sessionId: UUID, name: String) {
        sessionNames[sessionId] = name
        Self.saveNames(sessionNames)
    }
```

- [ ] **Step 3: Update `setName` to send rename to server**

Replace:
```swift
    func setName(_ name: String, for id: UUID) {
        sessionNames[id] = name
        Self.saveNames(sessionNames)
    }
```
With:
```swift
    func setName(_ name: String, for id: UUID) {
        sessionNames[id] = name
        Self.saveNames(sessionNames)
        Task {
            try? await sessionController?.renameSession(id: id, name: name)
        }
    }
```

- [ ] **Step 4: Update `createNewSession` to pass name to server**

In `createNewSession`, the name needs to be assigned *before* creating on server. Replace:

```swift
            let sessionId = try await controller.createSession()
            claimSession(sessionId)
            assignDefaultName(for: sessionId)
```
With:
```swift
            let name = pickDefaultName()
            let sessionId = try await controller.createSession(name: name)
            claimSession(sessionId)
            sessionNames[sessionId] = name
            Self.saveNames(sessionNames)
```

- [ ] **Step 5: Extract name-picking logic from `assignDefaultName`**

Replace `assignDefaultName` with a split — keep the picker pure and the setter separate:

Replace:
```swift
    private func assignDefaultName(for id: UUID) {
        let usedNames = Set(sessionNames.values)
        let themeNames = AppSettings.shared.sessionNamingTheme.names
        let available = themeNames.filter { !usedNames.contains($0) }
        let name = available.randomElement() ?? "Session \(sessionNames.count + 1)"
        sessionNames[id] = name
        Self.saveNames(sessionNames)
    }
```
With:
```swift
    private func pickDefaultName() -> String {
        let usedNames = Set(sessionNames.values)
        let themeNames = AppSettings.shared.sessionNamingTheme.names
        let available = themeNames.filter { !usedNames.contains($0) }
        return available.randomElement() ?? "Session \(sessionNames.count + 1)"
    }
```

- [ ] **Step 6: Update `fetchSessions` to merge server names**

In `fetchSessions`, after the line `sessions = try await controller.listSessions()`, add:

```swift
            // Merge server-side names into local cache (server wins).
            for session in sessions {
                if let serverName = session.name {
                    sessionNames[session.id] = serverName
                }
            }
            Self.saveNames(sessionNames)
```

- [ ] **Step 7: Update `attachRemoteSession` to use server name**

In `attachRemoteSession`, replace:

```swift
            if sessionNames[id] == nil {
                assignDefaultName(for: id)
            }
```
With:
```swift
            // Prefer the server-side name; fall back to local theme name.
            if sessionNames[id] == nil {
                let name = pickDefaultName()
                sessionNames[id] = name
                Self.saveNames(sessionNames)
                try? await controller.renameSession(id: id, name: name)
            }
```

- [ ] **Step 8: Update `name(for:)` to prefer server names**

In `name(for:)` — the current implementation already checks `sessionNames[id]`. Since we're merging server names into `sessionNames` in `fetchSessions`, this already works. The fallback chain is:
1. `sessionNames[id]` (populated from server or local)
2. Short UUID

No change needed to this method.

- [ ] **Step 9: Build the iOS app in Xcode**

Open `ClaudeRelay.xcodeproj` in Xcode, build (Cmd+B). Expected: Builds successfully.

- [ ] **Step 10: Commit**

```bash
git add ClaudeRelayApp/ViewModels/SessionCoordinator.swift
git commit -m "feat(ios): sync session names with server, broadcast renames"
```

---

## Task 8: Update `project.yml` — URL scheme + camera permission

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add camera permission and URL scheme**

In `project.yml`, in the `settings.base` section of `ClaudeRelayApp`, add after the speech recognition line:

```yaml
        INFOPLIST_KEY_NSCameraUsageDescription: "Claude Relay uses the camera to scan QR codes for session sharing."
```

For the URL scheme, add an `info` section to the `ClaudeRelayApp` target (after `settings`):

```yaml
    info:
      properties:
        CFBundleURLTypes:
          - CFBundleURLName: "com.claude.relay"
            CFBundleURLSchemes:
              - clauderelay
```

- [ ] **Step 2: Regenerate Xcode project**

Run: `cd "/Users/miguelriotinto/Desktop/Projects/Claude Relay" && xcodegen generate`
Expected: Project generated successfully.

- [ ] **Step 3: Commit**

```bash
git add project.yml
git commit -m "chore(ios): add camera permission and coderelay:// URL scheme"
```

---

## Task 9: Add QR code generation overlay to ActiveTerminalView

**Files:**
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift`

- [ ] **Step 1: Add QR code generation helper**

At the bottom of `ActiveTerminalView.swift`, add a standalone helper struct:

```swift
// MARK: - QR Code Generation

struct QRCodeGenerator {
    static func generate(from string: String, size: CGFloat = 200) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }
        let scale = size / ciImage.extent.size.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return UIImage(ciImage: scaled)
    }
}
```

Add `import CoreImage` at the top of the file (after the existing imports).

- [ ] **Step 2: Add QR overlay view**

Add after the `QRCodeGenerator`:

```swift
// MARK: - QR Code Overlay

struct QRCodeOverlay: View {
    let sessionId: UUID
    let sessionName: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 16) {
                if let image = QRCodeGenerator.generate(
                    from: "coderelay://session/\(sessionId.uuidString)",
                    size: 200
                ) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text(sessionName)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }
}
```

- [ ] **Step 3: Add state and QR button to ActiveTerminalView**

Add a `@State` property to `ActiveTerminalView`:

```swift
    @State private var showQROverlay = false
```

In the toolbar HStack, add the QR button between the session tabs `ScrollView` closing brace and the session name pill. Replace:

```swift
                // Fixed right: session name pill
                if let id = coordinator.activeSessionId {
```
With:
```swift
                // QR code button
                if coordinator.activeSessionId != nil {
                    ToolbarIconButton(icon: "qrcode") {
                        showQROverlay = true
                    }
                }

                // Fixed right: session name pill
                if let id = coordinator.activeSessionId {
```

- [ ] **Step 4: Add the overlay to the view**

Add the overlay after the existing `.overlay` for model loading (before the closing brace of the `body`):

```swift
        .overlay {
            if showQROverlay, let id = coordinator.activeSessionId {
                QRCodeOverlay(
                    sessionId: id,
                    sessionName: coordinator.name(for: id),
                    onDismiss: { showQROverlay = false }
                )
            }
        }
```

- [ ] **Step 5: Build the iOS app in Xcode**

Open Xcode, build (Cmd+B). Expected: Builds successfully.

- [ ] **Step 6: Commit**

```bash
git add ClaudeRelayApp/Views/ActiveTerminalView.swift
git commit -m "feat(ios): add QR code generation overlay to terminal view"
```

---

## Task 10: Create QRScannerView (UIViewRepresentable)

**Files:**
- Create: `ClaudeRelayApp/Views/QRScannerView.swift`

- [ ] **Step 1: Create the QR scanner view**

Create `ClaudeRelayApp/Views/QRScannerView.swift`:

```swift
import SwiftUI
import AVFoundation

/// Camera-based QR code scanner wrapped for SwiftUI.
struct QRScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onCodeScanned = onCodeScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let session = captureSession, !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let session = captureSession, session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
            }
        }
    }

    private func setupCamera() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)

        captureSession = session
        previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }

        hasScanned = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCodeScanned?(value)
    }
}
```

- [ ] **Step 2: Build in Xcode**

Expected: Builds successfully.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/Views/QRScannerView.swift
git commit -m "feat(ios): add QRScannerView (AVFoundation camera scanner)"
```

---

## Task 11: Add "Scan QR Code" button to Attach Session sheet

**Files:**
- Modify: `ClaudeRelayApp/Views/SessionSidebarView.swift`

- [ ] **Step 1: Add scanner state and button to AttachSessionSheet**

In the `AttachSessionSheet` struct, add state:

```swift
    @State private var showScanner = false
```

In the `AttachSessionSheet` body, add the scan button and scanner sheet. Replace the `NavigationStack` content:

After the `List` or `ContentUnavailableView` and before `.navigationTitle`, add a section for the QR button. The cleanest approach: wrap the existing `Group` content in a `VStack` and add the button at the bottom.

Replace the entire `body` of `AttachSessionSheet` with:

```swift
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if sessions.isEmpty {
                        ContentUnavailableView(
                            "No Sessions Available",
                            systemImage: "terminal",
                            description: Text("There are no other sessions running on the server.")
                        )
                    } else {
                        List(sessions, id: \.id) { session in
                            Button {
                                isPresented = false
                                Task { await coordinator.attachRemoteSession(id: session.id) }
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.name ?? coordinator.name(for: session.id))
                                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                                            .lineLimit(1)

                                        Text(String(session.id.uuidString.prefix(8)))
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }

                                    Spacer()

                                    Text(session.state.rawValue)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(attachBadgeColor(session.state).opacity(0.15))
                                        .foregroundStyle(attachBadgeColor(session.state))
                                        .clipShape(Capsule())
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }

                Divider()

                Button {
                    showScanner = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Attach Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet(coordinator: coordinator, isAttachSheetPresented: $isPresented, isScannerPresented: $showScanner)
            }
        }
        .presentationDetents([.medium])
    }
```

Note the key change: session names now use `session.name ?? coordinator.name(for: session.id)` — preferring the server-side name.

- [ ] **Step 2: Add QRScannerSheet**

Add after `AttachSessionSheet`:

```swift
// MARK: - QR Scanner Sheet

private struct QRScannerSheet: View {
    let coordinator: SessionCoordinator
    @Binding var isAttachSheetPresented: Bool
    @Binding var isScannerPresented: Bool

    var body: some View {
        NavigationStack {
            QRScannerView { scannedValue in
                handleScannedCode(scannedValue)
            }
            .ignoresSafeArea()
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isScannerPresented = false }
                }
            }
        }
    }

    private func handleScannedCode(_ value: String) {
        guard let url = URL(string: value),
              url.scheme == "clauderelay",
              url.host == "session",
              let uuidString = url.pathComponents.dropFirst().first,
              let sessionId = UUID(uuidString: uuidString) else {
            return  // Invalid QR code — silently ignore, keep scanning
        }

        isScannerPresented = false
        isAttachSheetPresented = false
        Task { await coordinator.attachRemoteSession(id: sessionId) }
    }
}
```

- [ ] **Step 3: Build in Xcode**

Expected: Builds successfully.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayApp/Views/SessionSidebarView.swift
git commit -m "feat(ios): add Scan QR Code button to attach session sheet"
```

---

## Task 12: Handle `onOpenURL` deep linking

**Files:**
- Modify: `ClaudeRelayApp/ClaudeRelayApp.swift`

- [ ] **Step 1: Add URL handling to the app**

In `ClaudeRelayApp.swift`, add an `onOpenURL` handler to the `WindowGroup`. Replace:

```swift
        WindowGroup {
            ZStack {
                ServerListView()

                if showSplash {
                    SplashScreenView {
                        showSplash = false
                    }
                    .transition(.identity)
                }
            }
            .task { await preloadSpeechModels() }
        }
```
With:
```swift
        WindowGroup {
            ZStack {
                ServerListView()

                if showSplash {
                    SplashScreenView {
                        showSplash = false
                    }
                    .transition(.identity)
                }
            }
            .task { await preloadSpeechModels() }
            .onOpenURL { url in
                handleDeepLink(url)
            }
        }
```

Add the handler method:

```swift
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "clauderelay",
              url.host == "session",
              let uuidString = url.pathComponents.dropFirst().first,
              let _ = UUID(uuidString: uuidString) else {
            return
        }
        // The primary QR use case (scanning from the attach sheet while
        // connected) is handled inline by QRScannerSheet. Cold-start deep
        // linking (app not connected) would require ServerListView to accept
        // a pending session ID — out of scope for this feature.
    }
```

- [ ] **Step 2: Build in Xcode**

Expected: Builds successfully.

- [ ] **Step 3: Commit**

```bash
git add ClaudeRelayApp/ClaudeRelayApp.swift
git commit -m "feat(ios): add onOpenURL handler for coderelay:// deep links"
```

---

## Task 13: Final integration build and test

**Files:** All modified files

- [ ] **Step 1: Run all SPM tests**

Run: `swift test 2>&1 | tail -30`
Expected: All tests pass (existing + new).

- [ ] **Step 2: Build iOS app in Xcode**

Open Xcode, clean build folder (Cmd+Shift+K), build (Cmd+B).
Expected: Clean build succeeds.

- [ ] **Step 3: Verify no compile warnings in modified files**

Check for warnings in Xcode's Issue navigator related to the modified files.
Expected: No new warnings.

- [ ] **Step 4: Commit if any final fixes were needed**

```bash
git add -A
git commit -m "chore: final integration fixes for session names + QR code"
```
