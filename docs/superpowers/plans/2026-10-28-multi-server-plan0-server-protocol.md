# Multi-Server Sessions — Plan 0: Server Identity and Protocol v3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every relay identifies itself on the wire with a persisted instance id and a display name, puts that id into push payloads, deep links and collapse keys, and exposes it on `/status`, so the client-side hub in later plans can tell servers apart and route notifications — while every existing v2 client keeps working unchanged.

**Architecture:** One new value type in CodeRelayKit (`ServerIdentity`) rides as an optional fifth associated value on `auth_success` and a fourth on `pair_success`, encoded as two flat optional JSON keys. The server mints and persists the id once (`~/.claude-relay/instance.json`), resolves the name from a new `serverName` config key or the host name, and injects the resulting `ServerIdentity` into `RelayMessageHandler`, `AdminRoutes` and `PushDispatcher` from `main.swift`. A small `LabelSanitizer` replaces the two duplicated control-character strippers and also sanitises `serverName`. `protocolVersion` goes 2 → 3; `minProtocolVersion` stays 0.

**Tech Stack:** Swift 6 / SwiftNIO (CodeRelayKit, CodeRelayServer, CodeRelayCLI), XCTest, `NIOAsyncTestingChannel` handler fixtures, `swift-crypto` SHA256.

**Spec:** `docs/superpowers/specs/2026-10-28-multi-server-sessions-design.md` — §5.2 (two ids, one job each), §6 (server changes and wire protocol v3), §10 (push payload and deep link), §13 (security), §15.2 (server tests), §16 Phase 0.

## Global Constraints

- **Backward compatible wire format.** `serverId`/`serverName` are optional on `auth_success` and `pair_success`, **omitted from the JSON when nil** (`encodeIfPresent`). A v2 client that ignores unknown keys (Swift `decodeIfPresent`, Kotlin `ignoreUnknownKeys = true` in `WireJson.kt`) is unaffected. `CodeRelayKit.protocolVersion` becomes `3`; `minProtocolVersion` stays `0`.
- **Deep link format (spec §10):** `coderelay://session/<UUID>?server=<instanceId>` — `server` is the instance id's `uuidString`, appended with `?server=`, nothing else in the query.
- **Collapse key (spec §6.3):** `"ws_" + hex(SHA256(instanceId + "\n" + groupId)).prefix(16)`. Still a hash; the raw path never leaves the host.
- **Instance file (spec §6.1):** `~/.claude-relay/instance.json`, JSON `{"id":"<uuid>","createdAt":"<iso8601>"}`, permissions `0o600`, created when missing, **replaced** (not fatal) when corrupt, with an error log line.
- **`serverName` (spec §6.1):** optional config key; sanitised like a pairing label (control characters and newlines stripped, trimmed, capped at 60 unicode scalars); empty clears it; default is the host name with a trailing `.local` removed; changes need a restart (read once at startup).
- **Injected, no defaults where it matters.** `ServerIdentity` is a **required** `RelayMessageHandler`/`WebSocketServer` parameter (same rule as `PairingCodeStore`: a defaulted per-connection value would give each connection its own identity). `AdminRoutes.handle` takes `identity: ServerIdentity? = nil` because it is a static router with many test call sites and `/status` simply omits the fields when nil.
- **Never log terminal text, prompts, drafts, tokens or secrets.** The instance id and server name may be logged.
- **Git hygiene:** `git add` explicit paths only (never `-A`/`.`); never `git stash`, `git checkout --`, `git clean`; commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Do not commit `Package.resolved` changes. No `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`/`CodeRelayKit.version`/Homebrew/AUR edits — releases are the user's `/coderelay-deploy`.
- **Gates:** `swift build 2>&1 | tail -3; echo EXIT=${pipestatus[1]}` and `swift test 2>&1 | tail -5; echo EXIT=${pipestatus[1]}` must both print `EXIT=0` (a piped `tail` hides a crash — never report "passed" without `EXIT=0`). Per-task filtered runs use `swift test --filter <Name> 2>&1 | grep -E "Test Suite '<Name>' (passed|failed)|Executed [0-9]+ tests|error:"`. The Linux CI job runs the same server tests: nothing Darwin-only (`Host.current()`, `sysctl`) in new code — use `ProcessInfo.processInfo.hostName`.
- **Never run the relay server binary directly** (`claude-relay-server --version` *starts a server*). Never `swift run claude-relay restart` here: the user's live Claude sessions run inside the relay. Tests only.
- **SwiftLint** (`swiftlint lint --quiet` from the repo root) must add no new warnings in touched files. `RelayMessageHandler.swift` is already 1019 lines (error ceiling 1000 is suppressed in-file); do not add more than the handful of lines specified. New tests go in **new** files.

## Review Focus

Inputs the spec implies but no existing test exercises; each has its test added to the owning task below.

1. **A `serverName` containing an ANSI escape or a newline** (`"\u{1B}[31mEvil\nrelay"`) must reach `auth_success` and the log stripped to `"[31mEvilrelay"`, never raw — Task 3 (`LabelSanitizerTests`) and Task 4 (handler test asserts the sanitised name on the wire).
2. **A corrupt or truncated `instance.json`** (e.g. `{"id":"not-a-uuid"`) must not keep the server from starting: a fresh id is minted and written, and the old file is overwritten — Task 2.
3. **A host name that is empty or just `.local`** must still produce a non-empty display name (`"CodeRelay"`) — Task 2.
4. **Two servers with the same `workingDir`** must produce *different* collapse keys, and the same server must produce the *same* key across calls (otherwise notifications never coalesce) — Task 5.
5. **A session whose `workingDir` is nil** (group `"~"`) must still get a `?server=` deep link and a namespaced collapse key — Task 5.

---

### Task 1: Kit — `ServerIdentity` and protocol v3 fields on `auth_success` / `pair_success`

**Files:**
- Create: `Sources/CodeRelayKit/Models/ServerIdentity.swift`
- Modify: `Sources/CodeRelayKit/CodeRelayKit.swift:6` (`protocolVersion`)
- Modify: `Sources/CodeRelayKit/Protocol/ServerMessage.swift:8` (`authSuccess` case), `:35` (`pairSuccess` case), `:90-94` (`PayloadCodingKeys`), `:99-102` (encode auth), `:157-160` (encode pair), `:175-179` (decode auth), `:252-256` (decode pair)
- Modify (pattern-match arity only): `Sources/CodeRelayClient/SessionController.swift:221`, `Sources/CodeRelayClient/PairingController.swift:74`, `Tests/CodeRelayKitTests/ServerMessageTests.swift:557`, `Tests/CodeRelayServerTests/WireIntegrationTests.swift:24`, `Tests/CodeRelayServerTests/WirePromptOptimizerTests.swift:15,134`, `Tests/CodeRelayServerTests/PairRequestHandlerTests.swift:101,136`
- Test: `Tests/CodeRelayKitTests/ServerIdentityMessageTests.swift` (new)

**Interfaces:**
- Produces: `public struct ServerIdentity: Equatable, Hashable, Sendable, Codable { public let id: UUID; public let name: String; public init(id: UUID, name: String) }` in CodeRelayKit.
- Produces: `ServerMessage.authSuccess(protocolVersion: Int? = nil, tokenId: String? = nil, capabilities: [String]? = nil, server: ServerIdentity? = nil)` and `ServerMessage.pairSuccess(token: String, tokenId: String, label: String, server: ServerIdentity? = nil)`. Wire keys: `serverId` (UUID string), `serverName` (string), both omitted when `server` is nil.
- Produces: `CodeRelayKit.protocolVersion == 3`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeRelayKitTests/ServerIdentityMessageTests.swift`:

```swift
import XCTest
@testable import CodeRelayKit

/// Protocol v3 (multi-server spec §6.2): `auth_success` and `pair_success` may
/// carry the relay's persisted instance id and display name. Both keys are
/// optional and omitted when absent, so v2 clients and servers interoperate.
final class ServerIdentityMessageTests: ProtocolTestCase {

    private let identity = ServerIdentity(
        id: UUID(uuidString: "0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D")!,
        name: "studio-mac")

    func testProtocolVersionIsThree() {
        XCTAssertEqual(CodeRelayKit.protocolVersion, 3)
        XCTAssertEqual(CodeRelayKit.minProtocolVersion, 0, "v3 is additive; old clients stay accepted")
    }

    func testAuthSuccessEncodesServerIdentityAsFlatKeys() throws {
        let msg = ServerMessage.authSuccess(protocolVersion: 3, tokenId: "tok", capabilities: nil, server: identity)
        let data = try encoder.encode(MessageEnvelope.server(msg))
        let payload = try XCTUnwrap(try jsonObject(data)["payload"] as? [String: Any])
        XCTAssertEqual(payload["serverId"] as? String, "0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D")
        XCTAssertEqual(payload["serverName"] as? String, "studio-mac")
    }

    func testAuthSuccessOmitsServerKeysWhenNil() throws {
        let data = try encoder.encode(MessageEnvelope.server(.authSuccess(protocolVersion: 3, tokenId: "tok")))
        let payload = try XCTUnwrap(try jsonObject(data)["payload"] as? [String: Any])
        XCTAssertNil(payload["serverId"])
        XCTAssertNil(payload["serverName"])
    }

    func testAuthSuccessDecodesServerIdentity() throws {
        let json = """
        {"type":"auth_success","payload":{"protocolVersion":3,"tokenId":"tok",
         "serverId":"0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D","serverName":"studio-mac"}}
        """
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .server(.authSuccess(protocolVersion: 3, tokenId: "tok", capabilities: nil, server: identity)))
    }

    func testAuthSuccessFromV2ServerDecodesWithNilIdentity() throws {
        let json = #"{"type":"auth_success","payload":{"protocolVersion":2,"tokenId":"tok"}}"#
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.authSuccess(_, _, _, let server)) = decoded else { return XCTFail("wrong case: \(decoded)") }
        XCTAssertNil(server)
    }

    func testAuthSuccessWithUnparsableServerIdDecodesAsNoIdentity() throws {
        // A malformed id must not fail the whole auth reply: identity is a hint.
        let json = #"{"type":"auth_success","payload":{"protocolVersion":3,"serverId":"nope","serverName":"x"}}"#
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.authSuccess(_, _, _, let server)) = decoded else { return XCTFail("wrong case: \(decoded)") }
        XCTAssertNil(server)
    }

    func testAuthSuccessWithIdButNoNameDecodesEmptyName() throws {
        let json = #"{"type":"auth_success","payload":{"serverId":"0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D"}}"#
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        guard case .server(.authSuccess(_, _, _, let server)) = decoded else { return XCTFail("wrong case: \(decoded)") }
        XCTAssertEqual(server, ServerIdentity(id: identity.id, name: ""))
    }

    func testPairSuccessRoundTripsServerIdentity() throws {
        let original = ServerMessage.pairSuccess(token: "t", tokenId: "i", label: "l", server: identity)
        let data = try encoder.encode(MessageEnvelope.server(original))
        let payload = try XCTUnwrap(try jsonObject(data)["payload"] as? [String: Any])
        XCTAssertEqual(payload["serverId"] as? String, identity.id.uuidString)
        XCTAssertEqual(payload["serverName"] as? String, "studio-mac")
        let decoded = try decoder.decode(MessageEnvelope.self, from: data)
        XCTAssertEqual(decoded, .server(original))
    }

    func testPairSuccessWithoutIdentityStillDecodes() throws {
        let json = #"{"type":"pair_success","payload":{"token":"t","tokenId":"i","label":"l"}}"#
        let decoded = try decoder.decode(MessageEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .server(.pairSuccess(token: "t", tokenId: "i", label: "l")))
    }

    func testServerIdentityCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(identity)
        XCTAssertEqual(try JSONDecoder().decode(ServerIdentity.self, from: data), identity)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head -5`
Expected: compile errors — `ServerIdentity` undefined, `authSuccess` has no `server:` label.

- [ ] **Step 3: Add `ServerIdentity`**

Create `Sources/CodeRelayKit/Models/ServerIdentity.swift`:

```swift
import Foundation

/// A relay's self-identification (multi-server spec §5.2, §6).
///
/// `id` is minted once per server install and persisted by the server
/// (`~/.claude-relay/instance.json`), so it survives restarts, host renames and
/// port changes. `name` is the operator-facing label: the `serverName` config
/// key when set, else the host name. Clients use `id` only to route push deep
/// links and to detect two bookmarks pointing at one relay — never as the key
/// for sessions, which stay scoped to the local bookmark.
public struct ServerIdentity: Equatable, Hashable, Sendable, Codable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    /// Builds the identity from the two optional wire keys. Returns nil when
    /// `serverId` is absent or not a UUID — a malformed hint must never fail
    /// the message that carries it. A missing name decodes as `""`.
    static func fromWire(serverId: String?, serverName: String?) -> ServerIdentity? {
        guard let serverId, let id = UUID(uuidString: serverId) else { return nil }
        return ServerIdentity(id: id, name: serverName ?? "")
    }
}
```

- [ ] **Step 4: Bump the protocol version**

In `Sources/CodeRelayKit/CodeRelayKit.swift` replace

```swift
    /// Current wire-protocol version. Bump when messages change in breaking ways.
    public static let protocolVersion = 2
```

with

```swift
    /// Current wire-protocol version. Bump when messages change in breaking ways.
    /// v3 (2026-10): `auth_success`/`pair_success` may carry `serverId`/`serverName`
    /// (multi-server spec §6.2). Additive — `minProtocolVersion` is unchanged.
    public static let protocolVersion = 3
```

- [ ] **Step 5: Extend the two cases, the coding keys, the encoders and the decoders**

In `Sources/CodeRelayKit/Protocol/ServerMessage.swift`:

Line 8, replace the case with:

```swift
    case authSuccess(protocolVersion: Int? = nil, tokenId: String? = nil, capabilities: [String]? = nil,
                     server: ServerIdentity? = nil)
```

Line 35, replace the case with:

```swift
    case pairSuccess(token: String, tokenId: String, label: String, server: ServerIdentity? = nil)
```

In `PayloadCodingKeys` (lines 90-94) add the two keys to the last line:

```swift
        case token, label, capabilities, status, original, prompt, serverId, serverName
```

Encode (lines 99-102), replace with:

```swift
        case .authSuccess(let protocolVersion, let tokenId, let capabilities, let server):
            try container.encodeIfPresent(protocolVersion, forKey: .protocolVersion)
            try container.encodeIfPresent(tokenId, forKey: .tokenId)
            try container.encodeIfPresent(capabilities, forKey: .capabilities)
            try container.encodeIfPresent(server?.id.uuidString, forKey: .serverId)
            try container.encodeIfPresent(server?.name, forKey: .serverName)
```

Encode pair (lines 157-160), replace with:

```swift
        case .pairSuccess(let token, let tokenId, let label, let server):
            try container.encode(token, forKey: .token)
            try container.encode(tokenId, forKey: .tokenId)
            try container.encode(label, forKey: .label)
            try container.encodeIfPresent(server?.id.uuidString, forKey: .serverId)
            try container.encodeIfPresent(server?.name, forKey: .serverName)
```

Decode auth (lines 175-179), replace with:

```swift
        case "auth_success":
            let protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
            let tokenId = try container.decodeIfPresent(String.self, forKey: .tokenId)
            let capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities)
            let server = ServerIdentity.fromWire(
                serverId: try container.decodeIfPresent(String.self, forKey: .serverId),
                serverName: try container.decodeIfPresent(String.self, forKey: .serverName))
            return .authSuccess(protocolVersion: protocolVersion, tokenId: tokenId,
                                capabilities: capabilities, server: server)
```

Decode pair (lines 252-256), replace with:

```swift
        case "pair_success":
            return .pairSuccess(
                token: try container.decode(String.self, forKey: .token),
                tokenId: try container.decode(String.self, forKey: .tokenId),
                label: try container.decode(String.self, forKey: .label),
                server: ServerIdentity.fromWire(
                    serverId: try container.decodeIfPresent(String.self, forKey: .serverId),
                    serverName: try container.decodeIfPresent(String.self, forKey: .serverName)))
```

- [ ] **Step 6: Fix the eight pattern-match sites (construction sites compile unchanged thanks to the defaults)**

Each pattern gains one trailing `_` (or a binding). Exact edits:

- `Sources/CodeRelayClient/SessionController.swift:221`
  `case .authSuccess(let serverProtocolVersion, let serverTokenId, let capabilities):` → `case .authSuccess(let serverProtocolVersion, let serverTokenId, let capabilities, _):`
- `Sources/CodeRelayClient/PairingController.swift:74`
  `guard case .pairSuccess(let token, _, let label) = reply else {` → `guard case .pairSuccess(let token, _, let label, _) = reply else {`
- `Tests/CodeRelayKitTests/ServerMessageTests.swift:557`
  `guard case .server(.authSuccess(_, let tokenId, _)) = decoded else {` → `guard case .server(.authSuccess(_, let tokenId, _, _)) = decoded else {`
- `Tests/CodeRelayServerTests/WireIntegrationTests.swift:24`
  `guard case .authSuccess(_, let tokenId, _) = reply else {` → `guard case .authSuccess(_, let tokenId, _, _) = reply else {`
- `Tests/CodeRelayServerTests/WirePromptOptimizerTests.swift:15`
  `guard case .authSuccess(_, _, let capabilities) = reply else {` → `guard case .authSuccess(_, _, let capabilities, _) = reply else {`
- `Tests/CodeRelayServerTests/WirePromptOptimizerTests.swift:134`
  `guard case .authSuccess(let version, let tokenId, let capabilities) = reply else {` → `guard case .authSuccess(let version, let tokenId, let capabilities, _) = reply else {`
- `Tests/CodeRelayServerTests/PairRequestHandlerTests.swift:101`
  `if case .pairSuccess(let token, let tokenId, let label) = msg { return (token, tokenId, label) }` → `if case .pairSuccess(let token, let tokenId, let label, _) = msg { return (token, tokenId, label) }`
- `Tests/CodeRelayServerTests/PairRequestHandlerTests.swift:136`
  `guard case .pairSuccess(let token, _, _)? = paired.first(where: {` → `guard case .pairSuccess(let token, _, _, _)? = paired.first(where: {`

Then confirm nothing else matches on arity: `grep -rn "\.authSuccess(\|\.pairSuccess(" Sources Tests CodeRelayApp CodeRelayMac | grep -v "Protocol/ServerMessage.swift"` and check every `case`/`guard case` line has four (auth) or four (pair) positions.

- [ ] **Step 7: Run the Kit tests and the whole build**

Run: `swift build --build-tests 2>&1 | grep -E "error:|Compiling|Build complete" | tail -3`
Expected: `Build complete!`

Run: `swift test --filter 'ServerIdentityMessageTests|ServerMessageTests|OptimizerProtocolMessageTests|PairingMessageTests' 2>&1 | grep -E "Test Suite '.*Tests' (passed|failed)|Executed [0-9]+ tests"`
Expected: all four suites `passed`, `ServerIdentityMessageTests` executed 10 tests.

Note `ServerMessageTests.swift:533` already uses `protocolVersion: 3` as an arbitrary value; it still passes.

- [ ] **Step 8: Commit**

```bash
git add Sources/CodeRelayKit/Models/ServerIdentity.swift Sources/CodeRelayKit/CodeRelayKit.swift \
  Sources/CodeRelayKit/Protocol/ServerMessage.swift Sources/CodeRelayClient/SessionController.swift \
  Sources/CodeRelayClient/PairingController.swift Tests/CodeRelayKitTests/ServerIdentityMessageTests.swift \
  Tests/CodeRelayKitTests/ServerMessageTests.swift Tests/CodeRelayServerTests/WireIntegrationTests.swift \
  Tests/CodeRelayServerTests/WirePromptOptimizerTests.swift Tests/CodeRelayServerTests/PairRequestHandlerTests.swift
git commit -m "feat(kit): protocol v3 — optional serverId/serverName on auth_success and pair_success

Adds ServerIdentity (multi-server spec §5.2/§6.2). Both keys are omitted
when nil so v2 clients and servers interoperate; a malformed serverId
decodes as 'no identity' rather than failing the reply.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Server — persisted instance id and name resolution (`ServerIdentityStore`)

**Files:**
- Modify: `Sources/CodeRelayKit/Models/RelayConfig.swift:183` (add `instanceFile` after `tokensFile`)
- Create: `Sources/CodeRelayServer/Services/ServerIdentityStore.swift`
- Test: `Tests/CodeRelayServerTests/ServerIdentityStoreTests.swift` (new)

**Interfaces:**
- Consumes: `ServerIdentity` (Task 1).
- Produces: `RelayConfig.instanceFile: URL` (`<configDirectory>/instance.json`).
- Produces: `enum ServerIdentityStore { static func load(directory: URL, configuredName: String?, hostName: String) -> ServerIdentity; static func resolveName(configured: String?, hostName: String) -> String }`. `load` never throws: it mints and writes when the file is missing or corrupt.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeRelayServerTests/ServerIdentityStoreTests.swift`:

```swift
import XCTest
@testable import CodeRelayKit
@testable import CodeRelayServer

/// `instance.json` (multi-server spec §6.1): minted once, reused forever,
/// `0o600`, and a corrupt file is replaced rather than taking the server down.
final class ServerIdentityStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerIdentityStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var file: URL { dir.appendingPathComponent("instance.json") }

    func testMintsAndPersistsOnFirstLoad() throws {
        let first = ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, first.id.uuidString)
        XCTAssertNotNil(json["createdAt"] as? String, "createdAt is an ISO-8601 string")
    }

    func testIdIsStableAcrossLoads() {
        let first = ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio")
        let second = ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio")
        XCTAssertEqual(first.id, second.id)
    }

    func testFileIsOwnerReadWriteOnly() throws {
        _ = ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptFileIsReplacedNotFatal() throws {
        try Data(#"{"id":"not-a-uuid""#.utf8).write(to: file)
        let identity = ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, identity.id.uuidString, "the corrupt file was overwritten with the new id")
        // And it is now stable.
        XCTAssertEqual(ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio").id, identity.id)
    }

    func testMissingDirectoryIsCreated() {
        let nested = dir.appendingPathComponent("nested/deeper", isDirectory: true)
        let identity = ServerIdentityStore.load(directory: nested, configuredName: nil, hostName: "studio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("instance.json").path))
        XCTAssertEqual(ServerIdentityStore.load(directory: nested, configuredName: nil, hostName: "studio").id, identity.id)
    }

    // MARK: - Name resolution

    func testConfiguredNameWins() {
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: "Studio Relay", hostName: "studio.local"), "Studio Relay")
    }

    func testHostNameDropsTrailingLocal() {
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: nil, hostName: "studio.local"), "studio")
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: "", hostName: "studio.local"), "studio")
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: nil, hostName: "build-box"), "build-box")
    }

    func testEmptyOrBareLocalHostNameFallsBackToCodeRelay() {
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: nil, hostName: ""), "CodeRelay")
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: nil, hostName: ".local"), "CodeRelay")
    }

    func testConfiguredNameIsSanitised() {
        // Control characters and newlines stripped, capped at 60 scalars — the
        // same rule as pairing labels, because the name reaches logs and clients.
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: "\u{1B}[31mEvil\nrelay", hostName: "h"), "[31mEvilrelay")
        let long = String(repeating: "n", count: 80)
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: long, hostName: "h").unicodeScalars.count, 60)
    }

    func testLoadUsesResolvedName() {
        let identity = ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio.local")
        XCTAssertEqual(identity.name, "studio")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'ServerIdentityStore' in scope`.

- [ ] **Step 3: Add `instanceFile` to `RelayConfig`**

In `Sources/CodeRelayKit/Models/RelayConfig.swift`, directly after line 183 (`public static let tokensFile = ...`) add:

```swift

    /// Persisted server instance identity (multi-server spec §6.1): a UUID
    /// minted once per install so clients can tell relays apart across
    /// restarts, host renames and port changes. Written `0o600`.
    public static let instanceFile: URL = configDirectory.appendingPathComponent("instance.json")
```

- [ ] **Step 4: Implement `ServerIdentityStore`**

Create `Sources/CodeRelayServer/Services/ServerIdentityStore.swift`:

```swift
import Foundation
import CodeRelayKit

/// Mints and persists the relay's `ServerIdentity` (multi-server spec §6.1).
///
/// The id lives in `instance.json` next to `config.json` and `tokens.json`;
/// it is created on first start and reused forever after. The name is **not**
/// persisted: it is resolved at every startup from the `serverName` config key
/// (sanitised like a pairing label) or, when unset, the host name — so renaming
/// a machine renames the relay without touching its identity.
///
/// `load` never throws. Like `ConfigManager.load()`, a corrupt file is worse
/// to die on than to replace: the old id is lost (clients re-learn it on their
/// next handshake), an error is logged, and a fresh id is written in its place.
enum ServerIdentityStore {

    private struct Persisted: Codable {
        let id: UUID
        let createdAt: Date
    }

    static let fileName = "instance.json"
    static let fallbackName = "CodeRelay"

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load(directory: URL = RelayConfig.configDirectory,
                     configuredName: String?,
                     hostName: String = ProcessInfo.processInfo.hostName) -> ServerIdentity {
        let file = directory.appendingPathComponent(fileName)
        let name = resolveName(configured: configuredName, hostName: hostName)
        let fm = FileManager.default

        if fm.fileExists(atPath: file.path) {
            do {
                let persisted = try decoder.decode(Persisted.self, from: Data(contentsOf: file))
                return ServerIdentity(id: persisted.id, name: name)
            } catch {
                RelayLogger.log(.error, category: "server",
                    "instance.json at \(file.path) is unreadable (\(error)); minting a new server id")
            }
        }

        let minted = Persisted(id: UUID(), createdAt: Date())
        do {
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try encoder.encode(minted).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            RelayLogger.log(category: "server", "Minted server id \(minted.id.uuidString)")
        } catch {
            // Still return a usable identity for this process; the next start
            // will try to persist again.
            RelayLogger.log(.error, category: "server",
                "Could not persist instance.json at \(file.path): \(error)")
        }
        return ServerIdentity(id: minted.id, name: name)
    }

    /// `serverName` when it survives sanitising, else the host name without a
    /// trailing `.local`, else `"CodeRelay"`.
    static func resolveName(configured: String?, hostName: String) -> String {
        if let configured {
            let clean = LabelSanitizer.sanitize(configured)
            if !clean.isEmpty { return clean }
        }
        var host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasSuffix(".local") { host.removeLast(".local".count) }
        let clean = LabelSanitizer.sanitize(host)
        return clean.isEmpty ? fallbackName : clean
    }
}
```

This references `LabelSanitizer`, created in Task 3. To keep this task green on its own, create it now with exactly the content Task 3 specifies — `Sources/CodeRelayServer/Network/LabelSanitizer.swift`:

```swift
import Foundation

/// The one rule for operator- or device-supplied labels that reach the log,
/// `TokenStore` or another client: trim, strip control characters and
/// newlines (a `\n` could forge a log line, an ESC could corrupt a terminal),
/// cap at 60 unicode scalars. Used for pairing labels (`handlePairRequest`,
/// `handlePairCreate`) and the `serverName` config key.
enum LabelSanitizer {
    static let maxScalars = 60

    static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.controlCharacters.union(.newlines).inverted
        let stripped = trimmed.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(stripped).prefix(maxScalars))
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter ServerIdentityStoreTests 2>&1 | grep -E "Test Suite 'ServerIdentityStoreTests' (passed|failed)|Executed [0-9]+ tests|error:"`
Expected: `passed`, `Executed 10 tests`.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodeRelayKit/Models/RelayConfig.swift Sources/CodeRelayServer/Services/ServerIdentityStore.swift \
  Sources/CodeRelayServer/Network/LabelSanitizer.swift Tests/CodeRelayServerTests/ServerIdentityStoreTests.swift
git commit -m "feat(server): persisted server instance id in instance.json with host-name fallback name

ServerIdentityStore mints a UUID once, writes it 0o600, reuses it across
restarts and replaces (never dies on) a corrupt file. The display name is
resolved per start from serverName or the host name. LabelSanitizer is
the shared label rule (multi-server spec §6.1).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `serverName` config key, shared `LabelSanitizer` in the two pairing paths

**Files:**
- Modify: `Sources/CodeRelayKit/Models/RelayConfig.swift` (field after `bindAll` ~line 51; memberwise `init` parameter + assignment; `CodingKeys`; `init(from:)`)
- Modify: `Sources/CodeRelayServer/Network/AdminRoutes.swift:124-134` (pair-create label block), `:454-456` (add `serverName` case after `bindAll`)
- Modify: `Sources/CodeRelayServer/Network/RelayMessageHandler.swift:612-619` (pair-request label block)
- Modify: `Sources/CodeRelayCLI/Commands/ConfigCommands.swift:67-75` (`validKeys`), `:155-158` (`restartHint`)
- Test: `Tests/CodeRelayServerTests/LabelSanitizerTests.swift` (new), `Tests/CodeRelayKitTests/RelayConfigTests.swift` (add two tests), `Tests/CodeRelayServerTests/ConfigValidationTests.swift` (add three tests), `Tests/CodeRelayCLITests/ConfigSetServerNameTests.swift` (new)

**Interfaces:**
- Consumes: `LabelSanitizer.sanitize(_:)` (created in Task 2).
- Produces: `RelayConfig.serverName: String?` (default nil, JSON key `serverName`), accepted by `AdminRoutes.applyConfigValue` and `claude-relay config set serverName <name>`; `ConfigSetCommand.restartHint(forKey: "serverName")` returns a hint.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeRelayServerTests/LabelSanitizerTests.swift`:

```swift
import XCTest
@testable import CodeRelayServer

final class LabelSanitizerTests: XCTestCase {
    func testTrimsWhitespaceAndNewlines() {
        XCTAssertEqual(LabelSanitizer.sanitize("  Studio \n"), "Studio")
    }

    func testStripsControlCharactersAndEmbeddedNewlines() {
        XCTAssertEqual(LabelSanitizer.sanitize("\u{1B}[31mEvil\nrelay\u{7F}"), "[31mEvilrelay")
    }

    func testCapsAtSixtyScalars() {
        let long = String(repeating: "é", count: 70)
        XCTAssertEqual(LabelSanitizer.sanitize(long).unicodeScalars.count, 60)
    }

    func testEmptyAndControlOnlyBecomeEmpty() {
        XCTAssertEqual(LabelSanitizer.sanitize(""), "")
        XCTAssertEqual(LabelSanitizer.sanitize("\n\t\u{07}"), "")
    }
}
```

Append to `Tests/CodeRelayKitTests/RelayConfigTests.swift` (inside the class, before its closing brace):

```swift

    // MARK: - serverName (multi-server spec §6.1)

    func testServerNameDefaultsToNil() throws {
        XCTAssertNil(RelayConfig.default.serverName)
        let decoded = try decoder.decode(RelayConfig.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.serverName, "a pre-v3 config.json has no serverName")
    }

    func testServerNameRoundTrips() throws {
        let config = RelayConfig(serverName: "Studio Relay")
        let data = try encoder.encode(config)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"serverName\" : \"Studio Relay\""))
        XCTAssertEqual(try decoder.decode(RelayConfig.self, from: data).serverName, "Studio Relay")
    }
```

Append to `Tests/CodeRelayServerTests/ConfigValidationTests.swift` (inside the class):

```swift

    // MARK: - serverName Validation

    func testServerNameIsSanitisedOnWrite() throws {
        var config = RelayConfig.default
        try AdminRoutes.applyConfigValue("  Studio\u{1B}[0m Relay\n", forKey: "serverName", to: &config)
        XCTAssertEqual(config.serverName, "Studio[0m Relay")
    }

    func testServerNameEmptyClears() throws {
        var config = RelayConfig(serverName: "Studio")
        try AdminRoutes.applyConfigValue("", forKey: "serverName", to: &config)
        XCTAssertNil(config.serverName)
        try AdminRoutes.applyConfigValue("\n\u{07}", forKey: "serverName", to: &config)
        XCTAssertNil(config.serverName, "control-only input is empty after sanitising")
    }

    func testServerNameMustBeAString() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(42, forKey: "serverName", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(true, forKey: "serverName", to: &config))
    }
```

Create `Tests/CodeRelayCLITests/ConfigSetServerNameTests.swift`:

```swift
import XCTest
@testable import CodeRelayCLI

/// `serverName` is read once at startup by ServerIdentityStore, so `config set`
/// must tell the operator a restart is needed — exactly like promptOptimizer*.
final class ConfigSetServerNameTests: XCTestCase {
    func testServerNameGetsTheRestartHint() {
        XCTAssertEqual(ConfigSetCommand.restartHint(forKey: "serverName"),
                       "Note: serverName is read at startup — run 'claude-relay restart' to apply.")
    }

    func testOtherKeysAreUnchanged() {
        XCTAssertNil(ConfigSetCommand.restartHint(forKey: "wsPort"))
        XCTAssertEqual(ConfigSetCommand.restartHint(forKey: "promptOptimizerEnabled"),
                       "Note: optimizer settings are read at startup — run 'claude-relay restart' to apply.")
    }

    func testServerNameIsAnAcceptedKey() {
        XCTAssertTrue(ConfigSetCommand.validKeys.contains("serverName"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head -5`
Expected: errors on `RelayConfig(serverName:)`, `.serverName`, `ConfigSetCommand.validKeys`.

- [ ] **Step 3: Add the field to `RelayConfig`**

In `Sources/CodeRelayKit/Models/RelayConfig.swift`:

After the `bindAll` property (line 51) add:

```swift

    /// Operator-facing name sent to clients in `auth_success`/`pair_success`
    /// (multi-server spec §6.1). Optional; nil means "use the host name".
    /// Sanitised on write like a pairing label. Read once at startup.
    public var serverName: String?
```

In the memberwise `init`, add a parameter after `bindAll: Bool = true,`:

```swift
        serverName: String? = nil,
```

and after `self.bindAll = bindAll` add:

```swift
        self.serverName = serverName
```

In `CodingKeys` change the line

```swift
        case tlsCert, tlsKey, logLevel, maxSessionsPerToken, bindAll
```

to

```swift
        case tlsCert, tlsKey, logLevel, maxSessionsPerToken, bindAll, serverName
```

In `init(from:)` after `self.bindAll = try c.decodeIfPresent(Bool.self, forKey: .bindAll) ?? true` add:

```swift
        self.serverName = try c.decodeIfPresent(String.self, forKey: .serverName)
```

- [ ] **Step 4: Accept the key server-side and reuse the sanitiser in both pairing paths**

In `Sources/CodeRelayServer/Network/AdminRoutes.swift`, in `applyConfigValue`, after the `case "bindAll":` block add:

```swift
        case "serverName":
            guard let val = value as? String else { throw ConfigError(message: "serverName must be a string") }
            let clean = LabelSanitizer.sanitize(val)
            config.serverName = clean.isEmpty ? nil : clean
```

In `handlePairCreate` (lines 124-134) replace

```swift
            let trimmed = rawLabel.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                // Apply the same sanitization as deviceName in handlePairRequest:
                // strip control characters and cap at 60 chars.
                let allowedChars = CharacterSet.controlCharacters.union(.newlines).inverted
                let stripped = trimmed.unicodeScalars.filter { allowedChars.contains($0) }
                label = String(String.UnicodeScalarView(stripped).prefix(60))
                if label?.isEmpty == true { label = nil }
            }
```

with

```swift
            // Same rule as deviceName in handlePairRequest and the serverName key.
            let clean = LabelSanitizer.sanitize(rawLabel)
            label = clean.isEmpty ? nil : clean
```

In `Sources/CodeRelayServer/Network/RelayMessageHandler.swift` (`handlePairRequest`, lines 612-619) replace

```swift
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmedName.isEmpty ? platform : trimmedName
        // Strip control characters (attacker-controlled deviceName/platform can
        // embed \n to forge log lines or ANSI escapes to corrupt terminals).
        let allowedChars = CharacterSet.controlCharacters.union(.newlines).inverted
        let stripped = sanitized.unicodeScalars.filter { allowedChars.contains($0) }
        let safeName = String(String.UnicodeScalarView(stripped).prefix(60))
```

with

```swift
        // Attacker-controlled deviceName/platform can embed \n to forge log
        // lines or ANSI escapes to corrupt terminals: one shared rule.
        var safeName = LabelSanitizer.sanitize(deviceName)
        if safeName.isEmpty { safeName = LabelSanitizer.sanitize(platform) }
```

- [ ] **Step 5: Teach the CLI the key and the restart hint**

In `Sources/CodeRelayCLI/Commands/ConfigCommands.swift`, hoist the key set so tests can see it. Replace lines 66-75 (`// Must match ...` through the closing `]`) with:

```swift
        guard Self.validKeys.contains(key) else {
```

(keeping the existing `FileHandle.standardError.write(... Valid keys: \(validKeys.sorted()...` body — change `validKeys` there to `Self.validKeys`), and add to `ConfigSetCommand` as a static property, next to `restartHint`:

```swift
    /// Must match server-side `AdminRoutes.applyConfigValue` accepted keys.
    static let validKeys: Set<String> = [
        "wsPort", "adminPort", "detachTimeout", "scrollbackSize",
        "tlsCert", "tlsKey", "logLevel", "maxSessionsPerToken",
        "bindAll", "serverName",
        "pushEnabled", "pushNotifyOnFinished",
        "apnsKeyPath", "apnsKeyId", "apnsTeamId", "apnsBundleId", "apnsUseSandbox",
        "fcmServiceAccountPath", "fcmProjectId",
        "promptOptimizerEnabled", "promptOptimizerProvider", "promptOptimizerModel",
        "promptOptimizerRegion", "promptOptimizerKeyPath", "promptOptimizerShareScreen"
    ]
```

Replace `restartHint` (lines 155-158) with:

```swift
    static func restartHint(forKey key: String) -> String? {
        if key == "serverName" {
            return "Note: serverName is read at startup — run 'claude-relay restart' to apply."
        }
        guard key.hasPrefix("promptOptimizer") else { return nil }
        return "Note: optimizer settings are read at startup — run 'claude-relay restart' to apply."
    }
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter 'LabelSanitizerTests|RelayConfigTests|ConfigValidationTests|ConfigSetServerNameTests|ConfigSetOptimizerValidationTests|PairRequestHandlerTests|PairCreateRouteTests' 2>&1 | grep -E "Test Suite '.*Tests' (passed|failed)|error:"`
Expected: all seven suites `passed` (the two pairing suites prove the sanitiser refactor preserved behaviour).

- [ ] **Step 7: Commit**

```bash
git add Sources/CodeRelayKit/Models/RelayConfig.swift Sources/CodeRelayServer/Network/AdminRoutes.swift \
  Sources/CodeRelayServer/Network/RelayMessageHandler.swift Sources/CodeRelayCLI/Commands/ConfigCommands.swift \
  Tests/CodeRelayServerTests/LabelSanitizerTests.swift Tests/CodeRelayKitTests/RelayConfigTests.swift \
  Tests/CodeRelayServerTests/ConfigValidationTests.swift Tests/CodeRelayCLITests/ConfigSetServerNameTests.swift
git commit -m "feat(config): serverName key, sanitised by the shared LabelSanitizer

The two duplicated pairing-label strippers now call LabelSanitizer, and
serverName goes through the same rule on write. The CLI accepts the key
and prints the restart hint (read once at startup).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Inject `ServerIdentity` — `auth_success`, `pair_success`, `/status`

**Files:**
- Modify: `Sources/CodeRelayServer/Network/RelayMessageHandler.swift:100-114` (init), `:526-527` (auth reply), `:665` (pair reply)
- Modify: `Sources/CodeRelayServer/Network/WebSocketServer.swift:35-52` (init + stored property), `:102-111` (handler factory)
- Modify: `Sources/CodeRelayServer/Network/AdminRoutes.swift:22-31` (`handle` signature), `/status` dictionary at `:230-237`
- Modify: `Sources/CodeRelayServer/Network/AdminHTTPServer.swift:19-31` (init + stored property), `:179-188` (call)
- Modify: `Sources/CodeRelayServer/main.swift` (load identity after config; pass to both servers; print it)
- Modify fixtures: `Tests/CodeRelayServerTests/RelayMessageHandlerTests.swift:52-60`, `Tests/CodeRelayServerTests/PairRequestHandlerTests.swift:38-46`, `Tests/CodeRelayServerTests/PromptRequestHandlerTests.swift:80-87`
- Test: `Tests/CodeRelayServerTests/ServerIdentityWireTests.swift` (new), `Tests/CodeRelayServerTests/AdminRoutesEndpointTests.swift` (add one test)

**Interfaces:**
- Consumes: `ServerIdentity`, `ServerIdentityStore.load` (Tasks 1–2), `RelayConfig.serverName` (Task 3).
- Produces: `RelayMessageHandler.init(..., pairingStore:, identity: ServerIdentity, optimizer:, optimizerBudget:)` — **required** `identity`; `WebSocketServer.init(..., pairingStore:, identity: ServerIdentity, ...)`; `AdminRoutes.handle(..., config:, identity: ServerIdentity? = nil, optimizer:, optimizeDeadline:)`; `AdminHTTPServer.init(..., config:, identity: ServerIdentity, rateLimiter:, optimizer:)`.
- Produces: `/status` JSON keys `instanceId` (UUID string) and `serverName` when identity is present.
- Produces: a global `let identity: ServerIdentity` in `main.swift` (used again in Task 5).

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeRelayServerTests/ServerIdentityWireTests.swift`:

```swift
import XCTest
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import CodeRelayServer
@testable import CodeRelayKit

/// The injected `ServerIdentity` must reach the wire on both pre-auth replies
/// (multi-server spec §6.2) exactly as resolved — sanitised name included.
final class ServerIdentityWireTests: SessionManagerTestCase {

    private let identity = ServerIdentity(
        id: UUID(uuidString: "0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D")!,
        name: "studio")

    private func makeChannel(pairingStore: PairingCodeStore = PairingCodeStore()) async throws -> NIOAsyncTestingChannel {
        let handler = RelayMessageHandler(
            sessionManager: makeManager(),
            tokenStore: tokenStore,
            rateLimiter: RateLimiter(maxAttempts: 100, windowSeconds: 60),
            clipboardService: NoopClipboardService(),
            pushStore: PushRegistrationStore(directory: tempDir),
            pairingStore: pairingStore,
            identity: identity,
            optimizerBudget: OptimizerBudget())
        let channel = await NIOAsyncTestingChannel(handler: handler)
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9999)).get()
        try await Task.sleep(for: .milliseconds(30))
        return channel
    }

    private func send(_ json: String, on channel: NIOAsyncTestingChannel) async throws {
        var buf = channel.allocator.buffer(capacity: json.utf8.count)
        buf.writeString(json)
        try await channel.writeInbound(WebSocketFrame(fin: true, opcode: .text, data: buf))
        try await Task.sleep(for: .milliseconds(50))
    }

    private func serverMessages(_ channel: NIOAsyncTestingChannel) async throws -> [ServerMessage] {
        var out: [ServerMessage] = []
        while let frame = try await channel.readOutbound(as: WebSocketFrame.self) {
            guard frame.opcode == .text else { continue }
            var data = frame.unmaskedData
            guard let bytes = data.readBytes(length: data.readableBytes) else { continue }
            if case .server(let message) = try JSONDecoder().decode(MessageEnvelope.self, from: Data(bytes)) {
                out.append(message)
            }
        }
        return out
    }

    func testAuthSuccessCarriesTheInjectedIdentity() async throws {
        let (plaintext, _) = try await tokenStore.create(label: "t")
        let channel = try await makeChannel()
        try await send(#"{"type":"auth_request","payload":{"token":"\#(plaintext)","protocolVersion":3}}"#, on: channel)
        let messages = try await serverMessages(channel)
        guard let auth = messages.first(where: { if case .authSuccess = $0 { return true } else { return false } }),
              case .authSuccess(let version, _, _, let server) = auth else {
            return XCTFail("expected auth_success, got \(messages)")
        }
        XCTAssertEqual(version, 3)
        XCTAssertEqual(server, identity)
    }

    func testPairSuccessCarriesTheInjectedIdentity() async throws {
        let store = PairingCodeStore()
        let grant = await store.mint(label: nil)
        let channel = try await makeChannel(pairingStore: store)
        try await send(#"{"type":"pair_request","payload":{"code":"\#(grant.code)","deviceName":"Phone","platform":"ios"}}"#, on: channel)
        let messages = try await serverMessages(channel)
        guard let paired = messages.first(where: { if case .pairSuccess = $0 { return true } else { return false } }),
              case .pairSuccess(_, _, _, let server) = paired else {
            return XCTFail("expected pair_success, got \(messages)")
        }
        XCTAssertEqual(server, identity)
    }
}
```

`SessionManagerTestCase` (`Tests/CodeRelayServerTests/SessionManagerTestCase.swift:231-253`) provides `tempDir`, `tokenStore` and `makeManager()`, which the fixture above uses.

In `Tests/CodeRelayServerTests/AdminRoutesEndpointTests.swift`, extend the private `route(` helper (lines 9-17) with one more defaulted parameter, `identity: ServerIdentity? = nil,` after `config: RelayConfig = .default,`, and pass `identity: identity,` to `AdminRoutes.handle(` after `config: config,`. Then append, after `testStatusEndpoint`:

```swift

    func testStatusReportsServerIdentityWhenInjected() async throws {
        let identity = ServerIdentity(id: UUID(), name: "studio")
        let (status, json) = await route(.GET, "/status", identity: identity)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json?["instanceId"] as? String, identity.id.uuidString)
        XCTAssertEqual(json?["serverName"] as? String, "studio")
    }

    func testStatusOmitsIdentityWhenNotInjected() async throws {
        let (_, json) = await route(.GET, "/status")
        XCTAssertNil(json?["instanceId"])
        XCTAssertNil(json?["serverName"])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head -5`
Expected: `extra argument 'identity' in call` for both `RelayMessageHandler` and `AdminRoutes.handle`.

- [ ] **Step 3: Thread the identity through the handler**

In `Sources/CodeRelayServer/Network/RelayMessageHandler.swift`:

Add a stored property next to `pairingStore` (find `let pairingStore: PairingCodeStore` near the top of the class):

```swift
    /// This relay's persisted identity, sent on every `auth_success` and
    /// `pair_success` (multi-server spec §6.2). Injected like `pairingStore`:
    /// constructed once in main.swift, never defaulted per connection.
    let identity: ServerIdentity
```

Replace the init (lines 100-114) with:

```swift
    init(sessionManager: SessionManager, tokenStore: TokenStore, rateLimiter: RateLimiter,
         clipboardService: ClipboardService,
         pushStore: PushRegistrationStore = PushRegistrationStore(directory: RelayConfig.configDirectory),
         pairingStore: PairingCodeStore,
         identity: ServerIdentity,
         optimizer: (any PromptOptimizing)? = nil,
         optimizerBudget: OptimizerBudget) {
        self.sessionManager = sessionManager
        self.tokenStore = tokenStore
        self.rateLimiter = rateLimiter
        self.clipboardService = clipboardService
        self.pushStore = pushStore
        self.pairingStore = pairingStore
        self.identity = identity
        self.optimizer = optimizer
        self.optimizerBudget = optimizerBudget
    }
```

Auth reply (lines 525-529), replace with:

```swift
                handler.sendServerMessage(
                    .authSuccess(protocolVersion: CodeRelayKit.protocolVersion, tokenId: payload.tokenId,
                                 capabilities: handler.optimizer == nil ? nil : [CodeRelayKit.promptOptimizerCapability],
                                 server: handler.identity),
                    context: ctx
                )
```

Pair reply (line 665), replace with:

```swift
                    .pairSuccess(token: payload.token, tokenId: payload.tokenId, label: payload.label,
                                 server: handler.identity),
```

- [ ] **Step 4: Thread it through `WebSocketServer`**

In `Sources/CodeRelayServer/Network/WebSocketServer.swift`: add `private let identity: ServerIdentity` next to `pairingStore`; add the parameter `identity: ServerIdentity,` directly after `pairingStore: PairingCodeStore,` in `init` and `self.identity = identity` after `self.pairingStore = pairingStore`; in the handler factory (lines 102-111) add `identity: identity,` after `pairingStore: pairingStore,`.

- [ ] **Step 5: Thread it through the admin side**

In `Sources/CodeRelayServer/Network/AdminRoutes.swift`, `handle` signature: add `identity: ServerIdentity? = nil,` after `config: RelayConfig,`. Find where `handle` dispatches `/status` (the call to the private status handler) and pass `identity` through: change the private handler's signature to accept `identity: ServerIdentity?` and, in the `info` dictionary (lines 230-237), make it `var info` and append:

```swift
        if let identity {
            info["instanceId"] = identity.id.uuidString
            info["serverName"] = identity.name
        }
```

In `Sources/CodeRelayServer/Network/AdminHTTPServer.swift`: add `private let identity: ServerIdentity`; add `identity: ServerIdentity,` after `config: RelayConfig,` in `init` with `self.identity = identity`; add `identity: identity,` after `config: config,` in the `AdminRoutes.handle(` call (line 186).

- [ ] **Step 6: Wire `main.swift`**

After the `config` load block (after line 25) add:

```swift

// Server identity (multi-server spec §6.1): a UUID minted once and persisted
// in instance.json, plus the operator-facing name. Both go out on every
// auth_success/pair_success and into push payloads so clients can tell
// relays apart. `serverName` is read here, once — a `config set` needs a restart.
let identity = ServerIdentityStore.load(configuredName: config.serverName)
```

Pass `identity: identity,` after `pairingStore: pairingStore,` in the `WebSocketServer(` call and after `config: config,` in the `AdminHTTPServer(` call. After `print("  Admin API: 127.0.0.1:\(config.adminPort)")` add:

```swift
print("  Identity:  \(identity.name) (\(identity.id.uuidString))")
```

and extend the "Server started" log line to end with `, identity \(identity.id.uuidString) '\(identity.name)'`.

- [ ] **Step 7: Update the three existing fixtures**

Add `identity: ServerIdentity(id: UUID(), name: "test-relay"),` directly after the `pairingStore:` argument in:
- `Tests/CodeRelayServerTests/RelayMessageHandlerTests.swift` (`makeFixture`, line ~58)
- `Tests/CodeRelayServerTests/PairRequestHandlerTests.swift` (line ~44)
- `Tests/CodeRelayServerTests/PromptRequestHandlerTests.swift` (line ~85)

- [ ] **Step 8: Build and run the affected suites**

Run: `swift build --build-tests 2>&1 | grep -E "error:|Build complete" | tail -3`
Expected: `Build complete!`

Run: `swift test --filter 'ServerIdentityWireTests|AdminRoutesEndpointTests|RelayMessageHandlerTests|PairRequestHandlerTests|PromptRequestHandlerTests|WireIntegrationTests|WirePromptOptimizerTests' 2>&1 | grep -E "Test Suite '.*Tests' (passed|failed)|error:"`
Expected: all seven `passed`.

- [ ] **Step 9: Commit**

```bash
git add Sources/CodeRelayServer/Network/RelayMessageHandler.swift Sources/CodeRelayServer/Network/WebSocketServer.swift \
  Sources/CodeRelayServer/Network/AdminRoutes.swift Sources/CodeRelayServer/Network/AdminHTTPServer.swift \
  Sources/CodeRelayServer/main.swift Tests/CodeRelayServerTests/ServerIdentityWireTests.swift \
  Tests/CodeRelayServerTests/AdminRoutesEndpointTests.swift Tests/CodeRelayServerTests/RelayMessageHandlerTests.swift \
  Tests/CodeRelayServerTests/PairRequestHandlerTests.swift Tests/CodeRelayServerTests/PromptRequestHandlerTests.swift
git commit -m "feat(server): send the server identity on auth_success/pair_success and /status

ServerIdentity is loaded once in main.swift and injected (required, like
PairingCodeStore) into RelayMessageHandler and AdminHTTPServer.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Push — server id in payloads, `?server=` deep link, namespaced collapse key

**Files:**
- Modify: `Sources/CodeRelayServer/Push/PushSending.swift:20-23` (protocol), `:36-47` (`CompositePushSender.send`)
- Modify: `Sources/CodeRelayServer/Push/APNsClient.swift:85-99` (`send` signature + payload)
- Modify: `Sources/CodeRelayServer/Push/FCMClient.swift:82-94` (`send` signature + payload)
- Modify: `Sources/CodeRelayServer/Push/PushDispatcher.swift:48-77` (stored `serverId`, init), `:153-154` (deep link + collapse), `:160-163` (send call), `:204-210` (`collapseKey`)
- Modify: `Sources/CodeRelayServer/main.swift:74-80` (pass `serverId`)
- Modify fixtures: `Tests/CodeRelayServerTests/PushDispatcherTests.swift:6-15,32-44`, `Tests/CodeRelayServerTests/PushHTTPTests.swift:25-34`, `Tests/CodeRelayServerTests/APNsClientTests.swift:72,111,120`, `Tests/CodeRelayServerTests/FCMClientTests.swift:62-63,88-89`
- Test: `Tests/CodeRelayServerTests/PushServerIdentityTests.swift` (new)

**Interfaces:**
- Consumes: `identity` global (Task 4).
- Produces: `PushSending.send(deviceToken:platform:topic:title:body:deepLink:collapseKey:serverId:)` — new trailing `serverId: String`.
- Produces: `PushDispatcher.init(sessionProvider:tokenProvider:sender:config:serverId: String, onDeadToken:now:)`; `PushDispatcher.collapseKey(for groupId: String, serverId: String) -> String`.
- Produces: APNs payload top-level key `serverId`; FCM `data.serverId`; `deepLink` = `coderelay://session/<uuid>?server=<serverId>`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeRelayServerTests/PushServerIdentityTests.swift`:

```swift
import XCTest
@testable import CodeRelayServer
@testable import CodeRelayKit

/// Multi-server spec §6.3/§10: pushes from different relays must not collapse
/// into each other, and a tap must know which relay to open.
final class PushServerIdentityTests: XCTestCase {

    private actor Recorder: PushSending {
        private(set) var sent: [(deepLink: String, collapseKey: String, serverId: String)] = []
        func send(deviceToken: String, platform: PushPlatform, topic: String?, title: String,
                  body: String, deepLink: String, collapseKey: String, serverId: String) async -> PushResult {
            sent.append((deepLink, collapseKey, serverId))
            return .delivered
        }
        func snapshot() -> [(deepLink: String, collapseKey: String, serverId: String)] { sent }
    }

    private let serverA = "0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D"
    private let serverB = "7A6B5C4D-3E2F-4A1B-8C9D-0E1F2A3B4C5D"

    private func session(_ id: UUID, dir: String?) -> SessionInfo {
        SessionInfo(id: id, name: nil, state: .activeAttached, tokenId: "R", createdAt: Date(),
                    cols: 80, rows: 24, activity: .agentActive, agent: "claude",
                    agentState: .blocked, title: nil, workingDir: dir)
    }

    private func dispatcher(serverId: String, sender: Recorder, sessions: [SessionInfo]) -> PushDispatcher {
        PushDispatcher(
            sessionProvider: { _ in sessions },
            tokenProvider: { _ in [PushRegistration(platform: .apns, token: "dev", deviceId: "d1", enabled: true,
                                                    notifyOnFinished: false, updatedAt: Date(), topic: nil)] },
            sender: sender,
            config: PushNotifyConfig(debounceInterval: 100, notifyOnFinished: false),
            serverId: serverId,
            onDeadToken: { _ in },
            now: { Date(timeIntervalSince1970: 0) })
    }

    func testCollapseKeyDiffersAcrossServersAndIsStableWithinOne() {
        let a1 = PushDispatcher.collapseKey(for: "/Users/alice/proj", serverId: serverA)
        let a2 = PushDispatcher.collapseKey(for: "/Users/alice/proj", serverId: serverA)
        let b = PushDispatcher.collapseKey(for: "/Users/alice/proj", serverId: serverB)
        XCTAssertEqual(a1, a2)
        XCTAssertNotEqual(a1, b, "same checkout path on two hosts must not collapse together")
        XCTAssertTrue(a1.hasPrefix("ws_"))
        XCTAssertEqual(a1.count, 3 + 16)
        XCTAssertFalse(a1.contains("alice"), "collapse key stays a hash")
    }

    func testDeepLinkCarriesTheServerQuery() async {
        let sid = UUID()
        let sender = Recorder()
        let d = dispatcher(serverId: serverA, sender: sender, sessions: [session(sid, dir: "/repo/a")])
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .blocked, revision: 1))
        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].deepLink, "coderelay://session/\(sid.uuidString)?server=\(serverA)")
        XCTAssertEqual(sent[0].serverId, serverA)
        XCTAssertEqual(sent[0].collapseKey, PushDispatcher.collapseKey(for: "/repo/a", serverId: serverA))
    }

    func testNilWorkingDirStillGetsServerScopedLinkAndKey() async {
        let sid = UUID()
        let sender = Recorder()
        let d = dispatcher(serverId: serverB, sender: sender, sessions: [session(sid, dir: nil)])
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .blocked, revision: 1))
        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].deepLink.hasSuffix("?server=\(serverB)"))
        XCTAssertEqual(sent[0].collapseKey, PushDispatcher.collapseKey(for: "~", serverId: serverB))
    }
}
```

Add to `Tests/CodeRelayServerTests/APNsClientTests.swift`, inside the existing test that asserts `json?["deepLink"]` (line ~90), the extra assertion:

```swift
        XCTAssertEqual(json?["serverId"] as? String, "srv-1")
```

and add to `Tests/CodeRelayServerTests/FCMClientTests.swift` next to the `data.deepLink` assertion (line ~75):

```swift
        XCTAssertEqual((msg["data"] as? [String: Any])?["serverId"] as? String, "srv-1")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head -5`
Expected: `extra argument 'serverId'` errors in the new tests.

- [ ] **Step 3: Extend the sender protocol and both providers**

`Sources/CodeRelayServer/Push/PushSending.swift`, protocol (lines 20-23):

```swift
public protocol PushSending: Sendable {
    /// `serverId` is the relay's instance id (multi-server spec §10); providers
    /// put it in the payload so a tap can be routed to the right relay.
    func send(deviceToken: String, platform: PushPlatform, topic: String?, title: String,
              body: String, deepLink: String, collapseKey: String, serverId: String) async -> PushResult
}
```

`CompositePushSender.send` (lines 36-47): add `, serverId: String` to the signature and `, serverId: serverId` to the forwarded call.

`Sources/CodeRelayServer/Push/APNsClient.swift` (lines 85-99): add `, serverId: String` to the signature and change the payload to:

```swift
            let payload: [String: Any] = [
                "aps": [
                    "alert": ["title": title, "body": body],
                    "sound": "default",
                    "thread-id": collapseKey,
                ],
                "deepLink": deepLink,
                "serverId": serverId,
            ]
```

`Sources/CodeRelayServer/Push/FCMClient.swift` (lines 82-94): add `, serverId: String` to the signature and change `"data": ["deepLink": deepLink],` to `"data": ["deepLink": deepLink, "serverId": serverId],`.

- [ ] **Step 4: Namespace the dispatcher**

In `Sources/CodeRelayServer/Push/PushDispatcher.swift`: add a stored property next to `sender`:

```swift
    /// This relay's instance id (`ServerIdentity.id.uuidString`): appended to
    /// every deep link and mixed into every collapse key (spec §6.3, §10).
    private let serverId: String
```

Add the parameter `serverId: String,` after `config: PushNotifyConfig,` in `init` and `self.serverId = serverId` after `self.config = config`.

Replace lines 153-154 with:

```swift
        let deepLink = "coderelay://session/\(target.id.uuidString)?server=\(serverId)"
        let collapseKey = Self.collapseKey(for: groupId, serverId: serverId)
```

In the `sender.send(` call add `, serverId: serverId` after `collapseKey: collapseKey`.

Replace `collapseKey(for:)` (lines 204-210) with:

```swift
    /// Privacy-safe, bounded collapse id: hashes the group **and** the relay's
    /// instance id, so a raw host path never reaches APNs/FCM and two relays
    /// with a checkout at the same path do not overwrite each other's
    /// notifications (spec §6.3).
    static func collapseKey(for groupId: String, serverId: String) -> String {
        let digest = SHA256.hash(data: Data((serverId + "\n" + groupId).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "ws_" + hex.prefix(16)
    }
```

In `Sources/CodeRelayServer/main.swift` add `serverId: identity.id.uuidString,` after the `config: PushNotifyConfig(...)` argument of `PushDispatcher(`.

- [ ] **Step 5: Update the existing fixtures**

- `Tests/CodeRelayServerTests/PushDispatcherTests.swift`: `FakeSender.send` gains `, serverId: String` in its signature (record nothing new); `makeDispatcher` passes `serverId: "11111111-1111-1111-1111-111111111111",` after `config:`.
- `Tests/CodeRelayServerTests/PushHTTPTests.swift`: `RecordingSender.send` gains `, serverId: String`; its two `sender.send(` call sites in `CompositePushSenderTests` gain `, serverId: "s"`.
- `Tests/CodeRelayServerTests/APNsClientTests.swift` lines 72, 111, 120 and `FCMClientTests.swift` lines 62-63, 88-89: append `, serverId: "srv-1"` to each `send(` call.

- [ ] **Step 6: Run the push suites**

Run: `swift test --filter 'PushServerIdentityTests|PushDispatcherTests|APNsClientTests|FCMClientTests|CompositePushSenderTests|PushHTTPTests' 2>&1 | grep -E "Test Suite '.*Tests' (passed|failed)|error:"`
Expected: all `passed`.

- [ ] **Step 7: Commit**

```bash
git add Sources/CodeRelayServer/Push/PushSending.swift Sources/CodeRelayServer/Push/APNsClient.swift \
  Sources/CodeRelayServer/Push/FCMClient.swift Sources/CodeRelayServer/Push/PushDispatcher.swift Sources/CodeRelayServer/main.swift \
  Tests/CodeRelayServerTests/PushServerIdentityTests.swift Tests/CodeRelayServerTests/PushDispatcherTests.swift \
  Tests/CodeRelayServerTests/PushHTTPTests.swift Tests/CodeRelayServerTests/APNsClientTests.swift Tests/CodeRelayServerTests/FCMClientTests.swift
git commit -m "feat(push): server id in payloads, ?server= deep links, collapse key namespaced by relay

Two relays with the same checkout path no longer overwrite each other's
notifications, and a tap carries the relay it belongs to (spec §6.3, §10).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: CLI — `claude-relay status` shows the identity

**Files:**
- Modify: `Sources/CodeRelayCLI/Commands/ServiceCommands.swift:189-195` (call), `:240-258` (`StatusResponse`)
- Modify: `Sources/CodeRelayCLI/Formatters/OutputFormatter.swift:38-64` (`formatStatus`)
- Test: `Tests/CodeRelayCLITests/OutputFormatterTests.swift` (add two tests)

**Interfaces:**
- Consumes: `/status` keys `instanceId`, `serverName` (Task 4).
- Produces: `OutputFormatter.formatStatus(running:version:pid:uptime:sessions:serverName: String? = nil, instanceId: String? = nil)`; `StatusResponse.instanceId`, `.serverName`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CodeRelayCLITests/OutputFormatterTests.swift` (inside the class):

```swift

    func testHumanStatusShowsIdentityWhenPresent() {
        let output = OutputFormatter.formatStatus(
            running: true, version: "0.3.31", pid: 1, uptime: 10, sessions: 0,
            serverName: "studio", instanceId: "0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D")
        XCTAssertTrue(output.contains("Name:       studio"))
        XCTAssertTrue(output.contains("Instance:   0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D"))
    }

    func testHumanStatusOmitsIdentityAgainstOlderServers() {
        let output = OutputFormatter.formatStatus(running: true, version: "0.3.30", pid: 1, uptime: 10, sessions: 0)
        XCTAssertFalse(output.contains("Name:"))
        XCTAssertFalse(output.contains("Instance:"))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: `extra argument 'serverName' in call`.

- [ ] **Step 3: Implement**

In `Sources/CodeRelayCLI/Formatters/OutputFormatter.swift` change the signature to

```swift
    public static func formatStatus(
        running: Bool,
        version: String?,
        pid: Int?,
        uptime: Int?,
        sessions: Int,
        serverName: String? = nil,
        instanceId: String? = nil
    ) -> String {
```

and, after the `Version:` block, add:

```swift
        if let serverName {
            lines.append("Name:       \(serverName)")
        }

        if let instanceId {
            lines.append("Instance:   \(instanceId)")
        }
```

In `Sources/CodeRelayCLI/Commands/ServiceCommands.swift`, `StatusResponse`: add `let instanceId: String?` and `let serverName: String?` properties and `case instanceId`, `case serverName` to `CodingKeys`. In the `formatStatus(` call (line ~189) add `serverName: response.serverName, instanceId: response.instanceId` after `sessions: response.sessions`.

- [ ] **Step 4: Run the CLI tests**

Run: `swift test --filter 'OutputFormatterTests|AdminClientTests' 2>&1 | grep -E "Test Suite '.*Tests' (passed|failed)|error:"`
Expected: both `passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeRelayCLI/Commands/ServiceCommands.swift Sources/CodeRelayCLI/Formatters/OutputFormatter.swift \
  Tests/CodeRelayCLITests/OutputFormatterTests.swift
git commit -m "feat(cli): status shows the relay's name and instance id

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Docs, full gates, lint

**Files:**
- Modify: `CLAUDE.md:347` (config keys paragraph) and the "Wire Protocol" section (protocol versioning paragraph)
- Modify: `Sources/CodeRelayServer/CLAUDE.md` (new section before "Prompt Optimizer")
- Modify: `README.md:426-427` (server message bullets)

- [ ] **Step 1: Document the config key and the protocol bump**

In `CLAUDE.md`, in the `**Config keys**:` paragraph, after the `bindAll` description's closing parenthesis and before `**Push`, insert:

```
`serverName` (optional; the relay's display name sent in `auth_success`/`pair_success` and shown by `claude-relay status`; sanitised like a pairing label — control characters stripped, 60 scalars; default is the host name without `.local`; **read once at startup**, so `config set serverName` needs a restart).
```

In the "Wire Protocol" section, replace the sentence

```
**Protocol versioning**: Client sends `protocolVersion` in `auth_request`; server responds with `protocolVersion` in `auth_success`. `minProtocolVersion` is 0 for backward compatibility with older clients.
```

with

```
**Protocol versioning**: Client sends `protocolVersion` in `auth_request`; server responds with `protocolVersion` in `auth_success`. `minProtocolVersion` is 0 for backward compatibility with older clients. **v3** (multi-server spec, `docs/superpowers/specs/2026-10-28-multi-server-sessions-design.md`) added optional `serverId`/`serverName` to `auth_success` and `pair_success` (`ServerIdentity` in CodeRelayKit; omitted when nil, so v2 peers interoperate), put `serverId` into push payloads and `?server=<id>` onto push deep links, and namespaced the push collapse key by instance id. The id lives in `~/.claude-relay/instance.json` (`ServerIdentityStore`), minted once and never regenerated unless the file is corrupt.
```

- [ ] **Step 2: Server CLAUDE.md section**

In `Sources/CodeRelayServer/CLAUDE.md`, before the `## Prompt Optimizer` heading, add:

```markdown
## Server Identity (multi-server spec §6)

`ServerIdentityStore.load` runs once in `main.swift`, right after the config
load, and the resulting `ServerIdentity` is **injected** into
`RelayMessageHandler` (required parameter, same rule as `PairingCodeStore`:
a per-connection default would mint a different id per socket),
`AdminHTTPServer` and `PushDispatcher`. Three invariants:

- `instance.json` is created once and reused; a corrupt file is replaced with a
  fresh id and an error log, never a crash (clients re-learn the id on the next
  handshake). It is written `0o600` like `tokens.json`.
- The name is **not** persisted: `serverName` config key (sanitised by
  `LabelSanitizer`, the same rule as pairing labels) else host name minus
  `.local`, else `"CodeRelay"`. Read once — a `config set serverName` needs a
  restart, and the CLI says so.
- Push collapse keys are `sha256(instanceId + "\n" + groupId)`, so two relays
  with a checkout at the same path do not collapse into one notification; the
  deep link is `coderelay://session/<uuid>?server=<instanceId>`.
```

- [ ] **Step 3: README bullets**

In `README.md` replace

```
- `pair_success` - Pairing code redeemed; carries the minted `token`, `tokenId`, and `label`
- `auth_success` / `auth_failure` - Authentication result (includes optional `protocolVersion`)
```

with

```
- `pair_success` - Pairing code redeemed; carries the minted `token`, `tokenId`, `label`, and (v3) the relay's `serverId`/`serverName`
- `auth_success` / `auth_failure` - Authentication result (includes optional `protocolVersion`, `capabilities`, and (v3) `serverId`/`serverName`)
```

- [ ] **Step 4: Full gates**

Run: `swift build 2>&1 | tail -3; echo EXIT=${pipestatus[1]}` — Expected: `EXIT=0`.
Run: `swift test 2>&1 | tail -5; echo EXIT=${pipestatus[1]}` — Expected: `EXIT=0` and `Test Suite 'All tests' passed`. (`PTYSessionCwdTests` has a known deterministic local failure on clean HEAD — if it is the only failure, confirm it fails identically on `main` with the same command before proceeding, and say so in the report.)
Run: `swiftlint lint --quiet 2>&1 | grep -E "ServerIdentity|LabelSanitizer|PushDispatcher|ServerMessage.swift|RelayConfig.swift|AdminRoutes.swift|ConfigCommands.swift|OutputFormatter.swift" ; echo done` — Expected: no new warnings on touched files.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md Sources/CodeRelayServer/CLAUDE.md README.md
git commit -m "docs: serverName key, protocol v3 server identity, push namespacing

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 6: Open the PR**

Branch `feat/multi-server-plan0-server-identity` from `main`. PR title `feat(server): protocol v3 server identity (multi-server plan 0)`. Body: summary of Tasks 1–6, the compatibility statement (v2 clients unaffected; keys omitted when nil), the test inventory, and the note that the Homebrew/AUR release is a separate `/coderelay-deploy server` run by the user. Wait for the macOS and Linux CI jobs (both run the server suite) to pass before requesting merge.
