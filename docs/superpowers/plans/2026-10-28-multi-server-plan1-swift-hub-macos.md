# Multi-Server Sessions — Plan 1: Swift `ServerHub` and macOS Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The macOS app shows the sessions of every enabled relay bookmark in one sidebar, grouped by server, with exactly one session attached at a time across all of them, cached rows for an unreachable server, and push/deep-link taps routed to the right relay.

**Architecture:** A new `ServerHub<Slot>` in CodeRelayClient owns one **unchanged-in-behaviour** per-server coordinator per enabled bookmark (the existing `SharedSessionCoordinator` through a small `ServerSlotCoordinating` protocol), merges their state into `[ServerSection]`, and holds the single global `activeRef: SessionRef?`. Each coordinator gets four additive changes only: a per-server ownership-store namespace, `detachActive()`, a published `serverIdentity`, and a read-only `isAuthRejected`. macOS re-roots `MainWindow`, the sidebar, the menu bar and the server window onto the hub. A prerequisite task fixes the Apple deep-link scheme check (`clauderelay` → `coderelay`) that silently drops every push tap today, and introduces a shared `SessionDeepLink` parser that understands the `?server=` query Phase 0 added.

**Tech Stack:** Swift 6, SwiftUI (macOS 14+), Combine, XCTest; SwiftPM targets `CodeRelayKit`/`CodeRelayClient` (tests via `swift test`), Xcode targets `CodeRelayMac`/`CodeRelayMacTests` (tests via `xcodebuild test`).

**Spec:** `docs/superpowers/specs/2026-10-28-multi-server-sessions-design.md` — §5 (identity model), §7 (`ServerHub`), §8.1 and §8.3 (shared behaviour, macOS), §9 (persistence and migration), §10 (push and deep links), §11 (management), §12 (edge cases), §15.1/§15.3 (tests), §16 Phase 1. Phase 0 (server identity, protocol v3) shipped as v0.3.31: `ServerIdentity`, `ServerMessage.authSuccess(..., server:)`, `pairSuccess(..., server:)`, deep links `coderelay://session/<uuid>?server=<instanceId>`.

## Global Constraints

- **Session addressing (spec §5.1):** `SessionRef(serverId: UUID, sessionId: UUID)`; `serverId` is the bookmark's `ConnectionConfig.id`, never the server instance id. Coordinator internals stay keyed by bare session `UUID`.
- **Server identity is learned, not a key (spec §5.2):** `ConnectionConfig.instanceId: UUID?` is written after the first v3 `auth_success`; used only for deep-link routing and duplicate-bookmark flagging.
- **Single attachment (spec §7.5, D9):** across all servers at most one session is attached; the hub awaits `detachActive()` on the previous coordinator **before** `switchToSession` on the next, with a 3 s budget.
- **Stagger (spec D10):** coordinator `i` starts and fans out `150 ms × i` after the first.
- **Offline servers keep cached rows (D4);** cached sections contribute zero to aggregate counts (§7.6).
- **Cap:** 8 enabled servers (D12); the ninth toggle is refused with an explanation.
- **Status polling (D11):** `ServerStatusChecker` runs only for **disabled** bookmarks on the management window.
- **Migration (§9):** one-time, idempotent, guarded by `<prefix>.hub.migrated`; only the bookmark named by today's `com.clauderelay.mac.lastServerId` is enabled, except when there is exactly one bookmark. Legacy keys `<prefix>.sessionNames`, `<prefix>.agentSessions`, `<prefix>.activeSession.<deviceId>`, `<prefix>.collapsedGroups.<deviceId>` are copied into `<prefix>.<serverId>.…` then deleted.
- **Deep link routing precedence (§10):** instance id → unique session id across live sections → single enabled server's `attachRemoteSession` → not-found notice. A disabled bookmark matched by instance id is enabled on demand with a notice.
- **One-server user sees no change (G8):** with one enabled bookmark the sidebar still shows one section header and otherwise identical rows; menu bar and notifications omit the server prefix.
- **Never log tokens.** Log lines may carry bookmark ids, instance ids, names and session ids.
- **Git hygiene:** `git add` explicit paths only; never `git stash`/`checkout --`/`clean`; trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Do not commit `Package.resolved` or the generated `CodeRelay.xcodeproj` changes unless `project.yml` changed (it does not in this plan). No version bumps — releases are the user's `/coderelay-deploy`.
- **Gates:** SwiftPM: `swift test 2>&1 | tail -5; echo EXIT=${pipestatus[1]}` → `EXIT=0`. Per-task: `swift test --filter <Suite> 2>&1 | grep -E "Test Suite '<Suite>' (passed|failed)|Executed [0-9]+ tests|error:"`. macOS app: `xcodebuild build -project CodeRelay.xcodeproj -scheme CodeRelayMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"` and `xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite 'CodeRelayMacTests.xctest' (passed|failed)|Executed [0-9]+ tests|error:"` (if the scheme does not run the test bundle, add `-only-testing:CodeRelayMacTests`). iOS must still compile: `xcodebuild build -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`.
- **Never run the relay server binary or `swift run claude-relay restart`** — the user's live sessions run inside the relay. Manual verification uses a second relay on another port if needed (`claude-relay-server` is **never** started by hand; use the test harness or ask the user).
- **SwiftLint**: `swiftlint lint --quiet` adds no warnings on touched files; new tests go in new files.

## Review Focus

1. **Two enabled bookmarks that resolve to the same relay** (same instance id after handshake) must both show, be flagged as duplicates on the management window, and never produce two attached sessions — Task 6 (`testDuplicateInstanceIdIsFlagged`) and Task 5 (invariant test).
2. **An enabled bookmark with no keychain token** must become an `authFailed("No token stored")` section with a Re-pair action, not a crash or a silent gap — Task 4 (`testMissingTokenBecomesAuthFailedSection`).
3. **Selecting a cached row while that server is reconnecting** must remember the selection and apply it when the server comes back, not drop it — Task 5 (`testSelectingOfflineRowIsAppliedWhenServerReturns`).
4. **Removing the bookmark of the active server** must detach first and clear `activeRef`, leaving no dangling attachment — Task 5 (`testRemoveActiveServerDetachesAndClearsActiveRef`).
5. **Migration when `lastServerId` names a bookmark that no longer exists** must leave every bookmark disabled (or the single one enabled) and drop the orphaned legacy maps — Task 7 (`testMigrationWithMissingLastServer`).

---

### Task 1: `SessionDeepLink` (Kit) and the Apple scheme fix

**Files:**
- Create: `Sources/CodeRelayKit/Protocol/SessionDeepLink.swift`
- Modify: `CodeRelayApp/CodeRelayApp.swift:121-127`, `CodeRelayApp/Views/SessionSidebarView.swift:349-355`, `CodeRelayMac/CodeRelayMacApp.swift:73-84`, `CodeRelayMac/Views/QRScannerView.swift:48-56`
- Test: `Tests/CodeRelayKitTests/SessionDeepLinkTests.swift` (new)

**Interfaces:**
- Produces: `public struct SessionDeepLink: Equatable, Sendable { public let sessionId: UUID; public let serverInstanceId: UUID?; public init(sessionId:serverInstanceId:); public init?(url: URL); public init?(string: String); public var urlString: String; public var url: URL }`. Accepts schemes `coderelay` (current) and `clauderelay` (QR codes printed by pre-rename builds); host `session`; first path component a UUID; optional `server` query item that must be a UUID (a malformed one is ignored, not fatal).

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeRelayKitTests/SessionDeepLinkTests.swift`:

```swift
import XCTest
@testable import CodeRelayKit

/// `coderelay://session/<uuid>?server=<instanceId>` (multi-server spec §10).
/// The parser is shared by the push tap, the QR scanner and the `onOpenURL`
/// handlers on every Apple client, so there is exactly one place that knows
/// the format.
final class SessionDeepLinkTests: XCTestCase {

    private let session = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let server = UUID(uuidString: "0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D")!

    func testFormatsWithServerQuery() {
        let link = SessionDeepLink(sessionId: session, serverInstanceId: server)
        XCTAssertEqual(link.urlString,
                       "coderelay://session/11111111-2222-3333-4444-555555555555?server=0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D")
    }

    func testFormatsWithoutServerQuery() {
        XCTAssertEqual(SessionDeepLink(sessionId: session).urlString,
                       "coderelay://session/11111111-2222-3333-4444-555555555555")
    }

    func testParsesWhatTheServerSends() {
        let link = SessionDeepLink(string: "coderelay://session/\(session.uuidString)?server=\(server.uuidString)")
        XCTAssertEqual(link, SessionDeepLink(sessionId: session, serverInstanceId: server))
    }

    func testParsesALegacyLinkWithoutServer() {
        XCTAssertEqual(SessionDeepLink(string: "coderelay://session/\(session.uuidString)"),
                       SessionDeepLink(sessionId: session, serverInstanceId: nil))
    }

    func testAcceptsThePreRenameSchemeForOldQRCodes() {
        XCTAssertEqual(SessionDeepLink(string: "clauderelay://session/\(session.uuidString)")?.sessionId, session)
    }

    func testRejectsOtherHostsSchemesAndNonUUIDs() {
        XCTAssertNil(SessionDeepLink(string: "coderelay://pair?host=a&port=1&tls=0&code=ABCDEFGH"))
        XCTAssertNil(SessionDeepLink(string: "https://session/\(session.uuidString)"))
        XCTAssertNil(SessionDeepLink(string: "coderelay://session/not-a-uuid"))
        XCTAssertNil(SessionDeepLink(string: "coderelay://session/"))
    }

    func testMalformedServerQueryIsIgnoredNotFatal() {
        let link = SessionDeepLink(string: "coderelay://session/\(session.uuidString)?server=nope")
        XCTAssertEqual(link?.sessionId, session)
        XCTAssertNil(link?.serverInstanceId)
    }

    func testRoundTrip() {
        let link = SessionDeepLink(sessionId: session, serverInstanceId: server)
        XCTAssertEqual(SessionDeepLink(url: link.url), link)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | grep -v "^error: SwiftCompile" | head -3`
Expected: `cannot find 'SessionDeepLink' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/CodeRelayKit/Protocol/SessionDeepLink.swift`:

```swift
import Foundation

/// `coderelay://session/<sessionId>?server=<instanceId>` — the link a push
/// notification, a QR code or another app hands a client to open a session
/// (multi-server spec §10). `server` is the relay's persisted instance id
/// (`ServerIdentity.id`); it is optional because v2 relays and hand-typed
/// links omit it, and a malformed value is ignored rather than failing the
/// whole link. The pre-rename `clauderelay` scheme is still accepted so QR
/// codes printed by old builds keep scanning.
public struct SessionDeepLink: Equatable, Sendable {
    public static let scheme = "coderelay"
    public static let legacyScheme = "clauderelay"
    public static let host = "session"
    public static let serverQueryItem = "server"

    public let sessionId: UUID
    public let serverInstanceId: UUID?

    public init(sessionId: UUID, serverInstanceId: UUID? = nil) {
        self.sessionId = sessionId
        self.serverInstanceId = serverInstanceId
    }

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == Self.scheme || scheme == Self.legacyScheme,
              url.host?.lowercased() == Self.host,
              let first = url.pathComponents.dropFirst().first,
              let sessionId = UUID(uuidString: first) else {
            return nil
        }
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == Self.serverQueryItem })?.value
        self.sessionId = sessionId
        self.serverInstanceId = raw.flatMap(UUID.init(uuidString:))
    }

    public init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url: url)
    }

    public var urlString: String {
        var s = "\(Self.scheme)://\(Self.host)/\(sessionId.uuidString)"
        if let serverInstanceId {
            s += "?\(Self.serverQueryItem)=\(serverInstanceId.uuidString)"
        }
        return s
    }

    /// Always valid: every component is a fixed token or a UUID string.
    public var url: URL { URL(string: urlString)! }
}
```

- [ ] **Step 4: Replace the four stale scheme checks**

`CodeRelayApp/CodeRelayApp.swift` lines 121-127 — replace

```swift
        guard url.scheme == "clauderelay",
              url.host == "session",
              let uuidString = url.pathComponents.dropFirst().first,
              let sessionId = UUID(uuidString: uuidString) else {
            return
        }
        pendingSessionId = sessionId
```

with

```swift
        // Phase 1 (iOS) will route on `link.serverInstanceId`; until then the
        // single coordinator attaches by session id as before.
        guard let link = SessionDeepLink(url: url) else { return }
        pendingSessionId = link.sessionId
```

`CodeRelayApp/Views/SessionSidebarView.swift` lines 349-355 — replace

```swift
        guard let url = URL(string: value),
              url.scheme == "clauderelay",
              url.host == "session",
              let uuidString = url.pathComponents.dropFirst().first,
              let sessionId = UUID(uuidString: uuidString) else {
            return  // Invalid QR code — silently ignore, keep scanning
        }
```

with

```swift
        guard let sessionId = SessionDeepLink(string: value)?.sessionId else {
            return  // Invalid QR code — silently ignore, keep scanning
        }
```

`CodeRelayMac/CodeRelayMacApp.swift` lines 73-84 — replace

```swift
        guard url.scheme == "clauderelay",
              url.host == "session",
              let uuidString = url.pathComponents.dropFirst().first,
              let uuid = UUID(uuidString: uuidString) else {
            return
        }
        Task { @MainActor in
            if let coordinator = ActiveCoordinatorRegistry.shared.coordinator {
                await coordinator.attachRemoteSession(id: uuid)
            }
        }
```

with

```swift
        guard let link = SessionDeepLink(url: url) else { return }
        Task { @MainActor in
            if let coordinator = ActiveCoordinatorRegistry.shared.coordinator {
                await coordinator.attachRemoteSession(id: link.sessionId)
            }
        }
```

(Task 8 replaces this body again with the hub route; this step only fixes the scheme so the fix is independently shippable.)

`CodeRelayMac/Views/QRScannerView.swift` lines 48-52 — replace

```swift
        if let url = URL(string: value), url.scheme == "clauderelay",
           url.host == "session",
           let uuidString = url.pathComponents.dropFirst().first,
           let uuid = UUID(uuidString: uuidString) {
```

with

```swift
        if let uuid = SessionDeepLink(string: value)?.sessionId {
```

Both app files already `import CodeRelayKit`; `SessionSidebarView.swift` (iOS) and `QRScannerView.swift` (Mac) — add `import CodeRelayKit` if missing (`grep -n "^import CodeRelayKit" <file>`).

- [ ] **Step 5: Run the tests and both app builds**

Run: `swift test --filter SessionDeepLinkTests 2>&1 | grep -E "Test Suite 'SessionDeepLinkTests' (passed|failed)|Executed [0-9]+ tests"` — Expected: passed, 8 tests.
Run: `xcodebuild build -project CodeRelay.xcodeproj -scheme CodeRelayMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"` — Expected: `BUILD SUCCEEDED`.
Run: `xcodebuild build -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"` — Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodeRelayKit/Protocol/SessionDeepLink.swift Tests/CodeRelayKitTests/SessionDeepLinkTests.swift \
  CodeRelayApp/CodeRelayApp.swift CodeRelayApp/Views/SessionSidebarView.swift \
  CodeRelayMac/CodeRelayMacApp.swift CodeRelayMac/Views/QRScannerView.swift
git commit -m "fix(apple): session deep links use the coderelay scheme via a shared SessionDeepLink parser

Both apps still checked url.scheme == \"clauderelay\" after the rename while
Info.plist registers coderelay and the server sends coderelay://, so every
push tap and scanned QR code was a no-op. SessionDeepLink (Kit) is the one
parser; it also reads the ?server= instance id Phase 0 added.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `SessionRef` and the bookmark fields (`enabled`, `instanceId`, `displayName`)

**Files:**
- Create: `Sources/CodeRelayKit/Models/SessionRef.swift`
- Modify: `Sources/CodeRelayClient/ConnectionConfig.swift` (whole file)
- Test: `Tests/CodeRelayKitTests/SessionRefTests.swift` (new), `Tests/CodeRelayClientTests/ConnectionConfigTests.swift` (add three tests)

**Interfaces:**
- Produces: `public struct SessionRef: Hashable, Codable, Sendable { public let serverId: UUID; public let sessionId: UUID; public init(serverId:sessionId:) }`.
- Produces: `ConnectionConfig` gains `public var enabled: Bool` (default `true`), `public var instanceId: UUID?`, `public var displayName: String?`; decoding a pre-feature bookmark yields `enabled == true`, both optionals nil. Memberwise init gains the three parameters with defaults after `useTLS`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeRelayKitTests/SessionRefTests.swift`:

```swift
import XCTest
@testable import CodeRelayKit

final class SessionRefTests: XCTestCase {
    func testEqualityIsOnBothIds() {
        let s = UUID(), a = UUID(), b = UUID()
        XCTAssertEqual(SessionRef(serverId: a, sessionId: s), SessionRef(serverId: a, sessionId: s))
        XCTAssertNotEqual(SessionRef(serverId: a, sessionId: s), SessionRef(serverId: b, sessionId: s),
                          "the same session UUID on two bookmarks is two refs")
    }

    func testCodableRoundTrip() throws {
        let ref = SessionRef(serverId: UUID(), sessionId: UUID())
        let data = try JSONEncoder().encode(ref)
        XCTAssertEqual(try JSONDecoder().decode(SessionRef.self, from: data), ref)
    }
}
```

Append inside `Tests/CodeRelayClientTests/ConnectionConfigTests.swift` (before the final `}`):

```swift

    // MARK: - Multi-server fields (spec §9)

    func testPreFeatureBookmarkDecodesEnabledWithNoIdentity() throws {
        let json = #"{"id":"0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D","name":"Studio","host":"studio.local","port":9200,"useTLS":false}"#
        let config = try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.enabled, "bookmarks saved before the feature stay usable")
        XCTAssertNil(config.instanceId)
        XCTAssertNil(config.displayName)
    }

    func testNewFieldsRoundTrip() throws {
        var config = ConnectionConfig(name: "Studio", host: "studio.local")
        config.enabled = false
        config.instanceId = UUID(uuidString: "0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D")
        config.displayName = "studio"
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertFalse(decoded.enabled)
    }

    func testMemberwiseInitDefaultsToEnabled() {
        XCTAssertTrue(ConnectionConfig(name: "a", host: "b").enabled)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | grep -v "^error: SwiftCompile" | head -3`
Expected: `cannot find 'SessionRef'` and `value of type 'ConnectionConfig' has no member 'enabled'`.

- [ ] **Step 3: Implement**

Create `Sources/CodeRelayKit/Models/SessionRef.swift`:

```swift
import Foundation

/// Addresses a session across servers (multi-server spec §5.1): the local
/// bookmark id plus the server-scoped session id. Session UUIDs are minted
/// per relay and die with it, so a bare `UUID` is only meaningful inside one
/// coordinator; everything that spans servers — the hub's active selection,
/// last-session restore, deep-link routing, sidebar selection — uses this.
public struct SessionRef: Hashable, Codable, Sendable {
    public let serverId: UUID
    public let sessionId: UUID

    public init(serverId: UUID, sessionId: UUID) {
        self.serverId = serverId
        self.sessionId = sessionId
    }
}
```

Replace `Sources/CodeRelayClient/ConnectionConfig.swift` with:

```swift
import Foundation

/// Configuration for connecting to a CodeRelay server — one saved bookmark.
public struct ConnectionConfig: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var useTLS: Bool
    /// Multi-server (spec §9): whether the hub keeps a live coordinator for
    /// this bookmark. Pre-feature bookmarks decode as enabled; the one-time
    /// migration then turns off every bookmark except the last-used one.
    public var enabled: Bool
    /// The relay's persisted instance id, learned from the first v3
    /// `auth_success` (spec §5.2). Routing hint only — never the session key.
    public var instanceId: UUID?
    /// The relay's own `serverName`, learned alongside `instanceId`.
    public var displayName: String?

    /// Constructs the WebSocket URL from the configuration properties.
    /// Returns `nil` if the stored host contains characters that RFC 3986
    /// forbids in a URL (a corrupted bookmark, for instance).
    public var wsURL: URL? {
        let scheme = useTLS ? "wss" : "ws"
        return URL(string: "\(scheme)://\(host):\(port)")
    }

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16 = 9200,
        useTLS: Bool = false,
        enabled: Bool = true,
        instanceId: UUID? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.enabled = enabled
        self.instanceId = instanceId
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, useTLS, enabled, instanceId, displayName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(UInt16.self, forKey: .port)
        useTLS = try c.decode(Bool.self, forKey: .useTLS)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        instanceId = try c.decodeIfPresent(UUID.self, forKey: .instanceId)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
    }
}
```

(Encoding stays synthesized through `CodingKeys`.)

- [ ] **Step 4: Run the tests**

Run: `swift test --filter 'SessionRefTests|ConnectionConfigTests|SavedConnectionStoreTests' 2>&1 | grep -E "Test Suite '.*Tests' (passed|failed)|error:"` — Expected: all three passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeRelayKit/Models/SessionRef.swift Sources/CodeRelayClient/ConnectionConfig.swift \
  Tests/CodeRelayKitTests/SessionRefTests.swift Tests/CodeRelayClientTests/ConnectionConfigTests.swift
git commit -m "feat(client): SessionRef and the enabled/instanceId/displayName bookmark fields

Pre-feature bookmarks decode as enabled with no identity (spec §5, §9).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: The four additive coordinator changes

**Files:**
- Modify: `Sources/CodeRelayClient/SessionController.swift:84-99` (new published `serverIdentity`), `:221-236` (set it in `authenticate`)
- Modify: `Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift:258-268` (init gains `ownershipKeyPrefix`), `:276-280` (mirror identity on auth), new members near `:1150` (`detachActive`, `isAuthRejected`, `connectionState`, `start`)
- Modify: `Sources/CodeRelayClient/ViewModels/RecoveryController.swift:59` (expose `isAuthRejected`)
- Test: `Tests/CodeRelayClientTests/SharedSessionCoordinatorHubHooksTests.swift` (new), `Tests/CodeRelayClientTests/SessionControllerTests.swift` (add one test)

**Interfaces:**
- Produces: `SessionController.serverIdentity: ServerIdentity?` (`@Published public private(set)`), set from `auth_success`.
- Produces: `SharedSessionCoordinator.init(connection:token:ownershipKeyPrefix: String? = nil)` — nil keeps today's `Self.keyPrefix`; the hub passes `"<keyPrefix>.<serverId>"`.
- Produces: `@Published public private(set) var serverIdentity: ServerIdentity?` on the coordinator; `public var isAuthRejected: Bool`; `public var connectionState: RelayConnection.ConnectionState`; `open func start() async` (default no-op; platform subclasses connect + handshake); `public func detachActive() async` — idempotent: detaches whatever is attached, clears `activeSessionId`, clears that view model, bounded by `detachBudget` (3 s), never throws.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeRelayClientTests/SharedSessionCoordinatorHubHooksTests.swift`:

```swift
import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

/// The additive hooks the multi-server hub needs from a per-server coordinator
/// (spec §7.4). Everything else about the coordinator is unchanged.
@MainActor
final class SharedSessionCoordinatorHubHooksTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        let suite = "HubHooksTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testOwnershipNamespaceIsolatesNamesPerServer() {
        let defaults = isolatedDefaults()
        let serverA = UUID(), serverB = UUID()
        let shared = UUID()   // same session UUID on both servers (ephemeral ids can collide in a test)
        let a = SharedSessionCoordinator(connection: RelayConnection(), token: "t",
                                         ownershipKeyPrefix: "test.\(serverA.uuidString)", defaults: defaults)
        let b = SharedSessionCoordinator(connection: RelayConnection(), token: "t",
                                         ownershipKeyPrefix: "test.\(serverB.uuidString)", defaults: defaults)
        a.sessionNames[shared] = "alpha"
        a.persistNamesForTest()
        b.sessionNames[shared] = "bravo"
        b.persistNamesForTest()

        let a2 = SharedSessionCoordinator(connection: RelayConnection(), token: "t",
                                          ownershipKeyPrefix: "test.\(serverA.uuidString)", defaults: defaults)
        let b2 = SharedSessionCoordinator(connection: RelayConnection(), token: "t",
                                          ownershipKeyPrefix: "test.\(serverB.uuidString)", defaults: defaults)
        XCTAssertEqual(a2.sessionNames[shared], "alpha")
        XCTAssertEqual(b2.sessionNames[shared], "bravo")
    }

    func testDefaultNamespaceIsTheClassPrefix() {
        let defaults = isolatedDefaults()
        let c = SharedSessionCoordinator(connection: RelayConnection(), token: "t", defaults: defaults)
        XCTAssertEqual(c.ownershipKeyPrefixForTest, SharedSessionCoordinator.keyPrefix)
    }

    func testDetachActiveWithNothingAttachedIsANoOp() async {
        let c = SharedSessionCoordinator(connection: RelayConnection(), token: "t", defaults: isolatedDefaults())
        await c.detachActive()
        XCTAssertNil(c.activeSessionId)
        XCTAssertFalse(c.showError, "nothing to detach is not an error")
    }

    func testDetachActiveClearsSelectionEvenWhenTheWireIsDead() async {
        // The connection was never opened, so the detach RPC cannot succeed; the
        // local selection must still be cleared within the budget so the hub can
        // attach on another server.
        let c = SharedSessionCoordinator(connection: RelayConnection(), token: "t", defaults: isolatedDefaults())
        c.detachBudget = .milliseconds(200)
        let id = UUID()
        c.terminalViewModels[id] = TerminalViewModel(sessionId: id, connection: c.connection)
        c.activeSessionId = id
        let started = ContinuousClock.now
        await c.detachActive()
        XCTAssertNil(c.activeSessionId)
        XCTAssertNil(c.terminalViewModels[id])
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "bounded by detachBudget")
        XCTAssertFalse(c.showError, "a failed detach on a dead socket is not surfaced; recovery reconciles")
    }

    func testIsAuthRejectedStartsFalse() {
        let c = SharedSessionCoordinator(connection: RelayConnection(), token: "t", defaults: isolatedDefaults())
        XCTAssertFalse(c.isAuthRejected)
        XCTAssertEqual(c.connectionState, .disconnected)
        XCTAssertNil(c.serverIdentity)
    }
}
```

Append inside `Tests/CodeRelayClientTests/SessionControllerTests.swift` (before the final `}`; the file already has a `FakeConnection` with `autoRespond`, used at lines 236 and 325 — copy that fixture style):

```swift

    func testAuthenticateRecordsTheServerIdentity() async throws {
        let identity = ServerIdentity(id: UUID(), name: "studio")
        let conn = FakeConnection()
        conn.autoRespond = { _ in .authSuccess(protocolVersion: 3, tokenId: "tok", capabilities: nil, server: identity) }
        let controller = SessionController(connection: conn)
        try await controller.authenticate(token: "t")
        XCTAssertEqual(controller.serverIdentity, identity)
    }

    func testAuthenticateAgainstV2LeavesIdentityNil() async throws {
        let conn = FakeConnection()
        conn.autoRespond = { _ in .authSuccess(protocolVersion: 2, tokenId: "tok") }
        let controller = SessionController(connection: conn)
        try await controller.authenticate(token: "t")
        XCTAssertNil(controller.serverIdentity)
    }
```

Check the existing tests at lines 236/325 for the exact `SessionController` construction and `authenticate` call shape and match them.

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | grep -v "^error: SwiftCompile" | head -4`
Expected: `extra argument 'ownershipKeyPrefix'`, `no member 'serverIdentity'`.

- [ ] **Step 3: `SessionController.serverIdentity`**

In `Sources/CodeRelayClient/SessionController.swift` after line 99 (`serverCapabilities`) add:

```swift
    /// The relay's self-identification from a v3 `auth_success` (multi-server
    /// spec §5.2). nil against v2 servers. Mirrored onto the bookmark by the hub
    /// and used only to route deep links and flag duplicate bookmarks.
    @Published public private(set) var serverIdentity: ServerIdentity?
```

In `authenticate`, change the pattern on line 221 to bind the fourth value and store it:

```swift
        case .authSuccess(let serverProtocolVersion, let serverTokenId, let capabilities, let server):
```

and after `self.serverCapabilities = Set(capabilities ?? [])` add `self.serverIdentity = server`.

- [ ] **Step 4: Coordinator init namespace and defaults injection**

In `SharedSessionCoordinator.swift` replace lines 258-268 (`public init(connection: RelayConnection, token: String) {` through `self.ownershipStore = store`) with:

```swift
    /// - Parameters:
    ///   - ownershipKeyPrefix: UserDefaults namespace for this coordinator's
    ///     names/agents/F3 state. nil → the platform `keyPrefix` (today's single
    ///     server behaviour). The multi-server hub passes
    ///     `"<keyPrefix>.<bookmarkId>"` so two relays never share a session map
    ///     (spec §7.4, D8).
    ///   - defaults: injected for tests; production uses `.standard`.
    public init(connection: RelayConnection, token: String,
                ownershipKeyPrefix: String? = nil,
                defaults: UserDefaults = .standard) {
        self.connection = connection
        self.token = token
        self.authCoordinator = AuthCoordinator(connection: connection, token: token)
        let prefix = ownershipKeyPrefix ?? Self.keyPrefix
        self.ownershipKeyPrefixForTest = prefix
        let store = SessionOwnershipStore(
            keyPrefix: prefix,
            deviceId: DeviceIdentifier().currentID,
            defaults: defaults
        )
        self.ownershipStore = store
```

Add the stored property next to `ownershipStore` (line ~193):

```swift
    /// The namespace the ownership store was built with; test hook only.
    public let ownershipKeyPrefixForTest: String
```

Replace the `onAuthenticated` closure (lines 276-280) with:

```swift
        authCoordinator.onAuthenticated = { [weak self] in
            guard let self else { return }
            self.serverIdentity = self.sessionController?.serverIdentity
            self.refreshOptimizerAvailability()
            self.didAuthenticate()
        }
```

- [ ] **Step 5: The published identity, status accessors, `start`, `detachActive`**

After `@Published public var isLoading = false` (line 50) add:

```swift
    /// Relay identity learned on auth (v3); nil before auth or against v2
    /// relays. The hub mirrors it onto the bookmark (spec §5.2).
    @Published public private(set) var serverIdentity: ServerIdentity?
    /// Bound on how long `detachActive()` waits for the detach RPC before
    /// proceeding anyway (spec §7.4, §12). Internal-settable for tests.
    public var detachBudget: Duration = .seconds(3)
```

After `cancelRecovery()` (line ~1171) add:

```swift
    // MARK: - Multi-server hub hooks (spec §7.4)

    /// True after the relay rejected this coordinator's token; the hub shows
    /// the section as `authFailed` and never retries on its own.
    public var isAuthRejected: Bool { recoveryController.isAuthRejected }

    /// The socket state, for the hub's section status (spec §7.2).
    public var connectionState: RelayConnection.ConnectionState { connection.state }

    /// Opens the socket and runs the launch handshake. The shared base has no
    /// bookmark to dial, so this is a no-op here; platform subclasses override
    /// (the macOS `SessionCoordinator.start()` already did exactly this).
    open func start() async {}

    /// Detaches whatever this coordinator has attached and clears the selection,
    /// so the hub can attach on another server (D9: one attachment across all
    /// servers). Idempotent. Bounded by `detachBudget`: a stuck server must not
    /// block a cross-server switch — the hub proceeds, the generation guard on
    /// the old socket discards a late reply, and recovery reconciles. A failure
    /// is logged at debug and never surfaced: the user asked for the *other*
    /// session.
    public func detachActive() async {
        guard let currentId = activeSessionId else { return }
        terminalViewModels[currentId]?.prepareForSwitch()
        terminalViewModels[currentId] = nil
        activeSessionId = nil
        let budget = detachBudget
        let controller = sessionController
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                do { try await controller?.detach() } catch {
                    recoveryLog.debug("detachActive: \(error.localizedDescription, privacy: .public)")
                }
            }
            group.addTask { try? await Task.sleep(for: budget) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Test hook: persist the in-memory names through the ownership store.
    public func persistNamesForTest() { ownershipStore.saveNames(sessionNames) }
```

`sessionController` is nil when never authenticated, so the detach RPC is skipped and only the local state clears — which is the no-wire test case above.

In `Sources/CodeRelayClient/ViewModels/RecoveryController.swift` next to `_testOnly_authRejected` (line 382) add:

```swift
    var isAuthRejected: Bool { authRejected }
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter 'SharedSessionCoordinatorHubHooksTests|SessionControllerTests|SharedSessionCoordinatorTests|RecoveryControllerTests|SessionHandshakeTests' 2>&1 | grep -E "Test Suite '.*Tests' (passed|failed)|error:"` — Expected: all passed.

- [ ] **Step 7: Commit**

```bash
git add Sources/CodeRelayClient/SessionController.swift Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift \
  Sources/CodeRelayClient/ViewModels/RecoveryController.swift \
  Tests/CodeRelayClientTests/SharedSessionCoordinatorHubHooksTests.swift Tests/CodeRelayClientTests/SessionControllerTests.swift
git commit -m "feat(client): coordinator hooks for the multi-server hub

Per-server ownership namespace, published serverIdentity from auth_success,
bounded idempotent detachActive(), isAuthRejected/connectionState and an
overridable start() — the four additive changes spec §7.4 allows.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `ServerHub` core — slots, sections, status, lifecycle

**Files:**
- Create: `Sources/CodeRelayClient/Hub/ServerSlotCoordinating.swift`, `Sources/CodeRelayClient/Hub/ServerSection.swift`, `Sources/CodeRelayClient/Hub/HubStateStore.swift`, `Sources/CodeRelayClient/Hub/ServerHub.swift`
- Modify: `Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift:9` (conformance), `Sources/CodeRelayClient/AuthManager.swift` (conform to `TokenProviding`)
- Test: `Tests/CodeRelayClientTests/Hub/FakeServerSlot.swift`, `Tests/CodeRelayClientTests/Hub/ServerHubTests.swift` (new)

**Interfaces:**
- Produces: `ServerSlotCoordinating` protocol (below); `SharedSessionCoordinator: ServerSlotCoordinating`.
- Produces: `ServerSectionStatus` (`connecting | live | reconnecting | offline | authFailed(String) | disabled`), `ServerSection`, `HubAggregate`.
- Produces: `HubStateStore(keyPrefix:deviceId:defaults:)` with `loadActiveRef()/saveActiveRef(_:)`, `loadCollapsedServers()/saveCollapsedServers(_:)`, `isMigrated/markMigrated()`.
- Produces: `TokenProviding` (`func loadToken(for: UUID) throws -> String?`), `AuthManager: TokenProviding`.
- Produces: `ServerHub<Slot: ServerSlotCoordinating>` with `init(bookmarks:tokens:stateStore:keyPrefix:factory:maxEnabled:stagger:sleep:)`, `@Published sections`, `@Published activeRef`, `@Published aggregate`, `var activeCoordinator: Slot?`, `func start() async`, `func stop()`, `func reloadBookmarks()`, `func setEnabled(_:Bool) -> Bool` (false when the cap refuses), `func slot(for serverId: UUID) -> Slot?`. Selection, fan-out, deep links, migration are Tasks 5–7 and extend this file.

- [ ] **Step 1: Write the fake slot and the failing tests**

Create `Tests/CodeRelayClientTests/Hub/FakeServerSlot.swift`:

```swift
import Foundation
import Combine
@testable import CodeRelayClient
@testable import CodeRelayKit

/// A scriptable stand-in for a per-server coordinator. Every hub test drives
/// the hub through this, so hub behaviour is proven against the protocol, not
/// against a live socket.
@MainActor
final class FakeServerSlot: ServerSlotCoordinating {
    let config: ConnectionConfig
    @Published var sessions: [SessionInfo] = []
    @Published var activeSessionId: UUID?
    @Published var isRecovering = false
    @Published var recoveryFailed = false
    @Published var isAuthRejected = false
    @Published var isPerformingHandshake = false
    @Published var connectionState: RelayConnection.ConnectionState = .disconnected
    @Published var serverIdentity: ServerIdentity?
    @Published var sessionLoadPhase: SessionLoadPhase?
    let activityCoordinator: ActivityCoordinator

    var activeSessions: [SessionInfo] { sessions.filter { !$0.state.isTerminal } }

    // Spies
    private(set) var startCount = 0
    private(set) var switchedTo: [UUID] = []
    private(set) var detachActiveCount = 0
    private(set) var createCount = 0
    private(set) var foregroundCount = 0
    private(set) var userRecoveryCount = 0
    private(set) var tornDown = false
    private(set) var pushSyncs: [(Bool, Bool)] = []
    private(set) var remoteAttaches: [UUID] = []
    private(set) var fetchCount = 0
    /// Order of calls across slots, written into a shared log by the test.
    var log: ((String) -> Void)?
    /// Makes `detachActive` hang until released (for the budget test).
    var detachGate: CheckedContinuation<Void, Never>?
    var detachHangs = false

    init(config: ConnectionConfig, defaults: UserDefaults) {
        self.config = config
        let store = SessionOwnershipStore(keyPrefix: "fake.\(config.id.uuidString)", deviceId: "d", defaults: defaults)
        self.activityCoordinator = ActivityCoordinator(ownershipStore: store, initialAgents: [:])
    }

    func start() async { startCount += 1; log?("start:\(config.name)") }
    func switchToSession(id: UUID) async { switchedTo.append(id); activeSessionId = id; log?("switch:\(config.name)") }
    func createNewSession() async { createCount += 1; let id = UUID(); activeSessionId = id; log?("create:\(config.name)") }
    func detachActive() async {
        detachActiveCount += 1; log?("detach:\(config.name)")
        if detachHangs { await withCheckedContinuation { detachGate = $0 } }
        activeSessionId = nil
    }
    func handleForegroundTransition(userInitiated: Bool) async { foregroundCount += 1; log?("fg:\(config.name)") }
    func triggerUserRecovery() { userRecoveryCount += 1; log?("recover:\(config.name)") }
    func tearDown() { tornDown = true; log?("teardown:\(config.name)") }
    func syncPushRegistration(pushEnabled: Bool, notifyOnFinished: Bool) async { pushSyncs.append((pushEnabled, notifyOnFinished)) }
    func attachRemoteSession(id: UUID, serverName: String?) async { remoteAttaches.append(id); activeSessionId = id }
    func fetchSessions(force: Bool) async { fetchCount += 1 }

    // Helpers
    func goLive(with sessions: [SessionInfo]) {
        connectionState = .connected
        isPerformingHandshake = false
        self.sessions = sessions
    }
    func goOffline() { connectionState = .disconnected }
}

/// Shared test scaffolding for hub tests.
@MainActor
struct HubHarness {
    let defaults: UserDefaults
    let bookmarks: SavedConnectionStore
    let tokens: FakeTokens
    let state: HubStateStore
    private(set) var slots: [UUID: FakeServerSlot] = [:]
    var hub: ServerHub<FakeServerSlot>!
    var sleeps: [Duration] = []

    final class FakeTokens: TokenProviding {
        var tokens: [UUID: String] = [:]
        func loadToken(for connectionId: UUID) throws -> String? { tokens[connectionId] }
    }

    init(configs: [ConnectionConfig], tokensFor: [UUID]? = nil, stagger: Duration = .milliseconds(150)) {
        let suite = "HubTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        bookmarks = SavedConnectionStore(key: "hub.bookmarks", defaults: defaults)
        bookmarks.saveAll(configs)
        tokens = FakeTokens()
        for c in configs where tokensFor?.contains(c.id) ?? true { tokens.tokens[c.id] = "tok-\(c.name)" }
        state = HubStateStore(keyPrefix: "hub.test", deviceId: "d", defaults: defaults)
        var captured: [UUID: FakeServerSlot] = [:]
        let d = defaults
        var sleepLog: [Duration] = []
        hub = ServerHub(bookmarks: bookmarks, tokens: tokens, stateStore: state, keyPrefix: "hub.test",
                        factory: { config, _ in
                            let s = FakeServerSlot(config: config, defaults: d)
                            captured[config.id] = s
                            return s
                        },
                        maxEnabled: 8, stagger: stagger,
                        sleep: { sleepLog.append($0) })
        _ = captured; _ = sleepLog
    }

    func slot(_ id: UUID) -> FakeServerSlot? { hub.slot(for: id) }
}

func makeConfig(_ name: String, enabled: Bool = true) -> ConnectionConfig {
    ConnectionConfig(name: name, host: "\(name).local", enabled: enabled)
}

func makeSession(_ id: UUID = UUID(), dir: String? = "/repo", state: SessionState = .activeDetached,
                 agentState: AgentDetectedState? = nil) -> SessionInfo {
    SessionInfo(id: id, name: nil, state: state, tokenId: "tok", createdAt: Date(), cols: 80, rows: 24,
                activity: agentState == nil ? nil : .agentActive, agent: agentState == nil ? nil : "claude",
                agentState: agentState, title: nil, workingDir: dir)
}
```

Note: `HubHarness.init` captures `captured`/`sleepLog` only to show the closure shapes; the tests below read slots through `hub.slot(for:)` and the stagger through the hub's `sleep` hook, so replace `_ = captured; _ = sleepLog` by nothing if the compiler flags the unused mutation — the factory closure may simply `return FakeServerSlot(config: config, defaults: d)`.

Create `Tests/CodeRelayClientTests/Hub/ServerHubTests.swift`:

```swift
import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

@MainActor
final class ServerHubTests: XCTestCase {

    func testStartBuildsOneSlotPerEnabledBookmarkOnly() async {
        let a = makeConfig("a"), b = makeConfig("b", enabled: false), c = makeConfig("c")
        let h = HubHarness(configs: [a, b, c])
        await h.hub.start()
        XCTAssertNotNil(h.slot(a.id)); XCTAssertNil(h.slot(b.id)); XCTAssertNotNil(h.slot(c.id))
        XCTAssertEqual(h.slot(a.id)?.startCount, 1)
        XCTAssertEqual(h.hub.sections.map(\.id), [a.id, b.id, c.id], "sections follow bookmark order, disabled included")
        XCTAssertEqual(h.hub.sections[1].status, .disabled)
    }

    func testStartStaggersSlotStarts() async {
        let a = makeConfig("a"), b = makeConfig("b"), c = makeConfig("c")
        let h = HubHarness(configs: [a, b, c], stagger: .milliseconds(150))
        var order: [String] = []
        h.hub.onTestEvent = { order.append($0) }
        await h.hub.start()
        // sleep(0), start a, sleep(150ms), start b, sleep(300ms), start c — the
        // hub's `sleep` hook records the requested delays in order.
        XCTAssertEqual(h.hub.recordedSleeps, [.zero, .milliseconds(150), .milliseconds(300)])
        XCTAssertEqual(order.filter { $0.hasPrefix("start:") }, ["start:a", "start:b", "start:c"])
    }

    func testStatusDerivation() {
        typealias S = ServerSectionStatus
        XCTAssertEqual(S.derive(enabled: false, connection: .connected, isRecovering: false, isPerformingHandshake: false,
                                authRejected: false, recoveryFailed: false), .disabled)
        XCTAssertEqual(S.derive(enabled: true, connection: .connected, isRecovering: false, isPerformingHandshake: false,
                                authRejected: true, recoveryFailed: false), .authFailed("Token rejected by the relay"))
        XCTAssertEqual(S.derive(enabled: true, connection: .disconnected, isRecovering: true, isPerformingHandshake: false,
                                authRejected: false, recoveryFailed: false), .reconnecting)
        XCTAssertEqual(S.derive(enabled: true, connection: .connected, isRecovering: false, isPerformingHandshake: false,
                                authRejected: false, recoveryFailed: false), .live)
        XCTAssertEqual(S.derive(enabled: true, connection: .connected, isRecovering: false, isPerformingHandshake: true,
                                authRejected: false, recoveryFailed: false), .connecting)
        XCTAssertEqual(S.derive(enabled: true, connection: .connecting, isRecovering: false, isPerformingHandshake: false,
                                authRejected: false, recoveryFailed: false), .connecting)
        XCTAssertEqual(S.derive(enabled: true, connection: .disconnected, isRecovering: false, isPerformingHandshake: false,
                                authRejected: false, recoveryFailed: true), .offline)
        XCTAssertEqual(S.derive(enabled: true, connection: .disconnected, isRecovering: false, isPerformingHandshake: false,
                                authRejected: false, recoveryFailed: false), .offline)
    }

    func testOfflineSectionKeepsCachedRowsAndCountsNothing() async {
        let a = makeConfig("a")
        let h = HubHarness(configs: [a])
        await h.hub.start()
        let s1 = makeSession(agentState: .blocked)
        h.slot(a.id)!.goLive(with: [s1])
        await Task.yield()
        XCTAssertEqual(h.hub.sections[0].status, .live)
        XCTAssertEqual(h.hub.sections[0].sessions.map(\.id), [s1.id])
        XCTAssertFalse(h.hub.sections[0].isCached)
        XCTAssertEqual(h.hub.aggregate.sessionsAwaitingInput, 0, "blocked is counted via ActivityCoordinator; none reported yet")

        h.slot(a.id)!.goOffline()
        h.slot(a.id)!.sessions = []     // a dropped socket empties the live list
        await Task.yield()
        XCTAssertEqual(h.hub.sections[0].status, .offline)
        XCTAssertEqual(h.hub.sections[0].sessions.map(\.id), [s1.id], "cached rows survive the drop (D4)")
        XCTAssertTrue(h.hub.sections[0].isCached)
        XCTAssertEqual(h.hub.aggregate.liveServers, 0)
    }

    func testFreshListReplacesCachedRowsAfterReconnect() async {
        let a = makeConfig("a")
        let h = HubHarness(configs: [a])
        await h.hub.start()
        let old = makeSession(), fresh = makeSession()
        h.slot(a.id)!.goLive(with: [old]); await Task.yield()
        h.slot(a.id)!.goOffline(); h.slot(a.id)!.sessions = []; await Task.yield()
        h.slot(a.id)!.goLive(with: [fresh]); await Task.yield()
        XCTAssertEqual(h.hub.sections[0].sessions.map(\.id), [fresh.id], "replaced, not merged (spec §5.3)")
    }

    func testMissingTokenBecomesAuthFailedSection() async {
        let a = makeConfig("a"), b = makeConfig("b")
        let h = HubHarness(configs: [a, b], tokensFor: [a.id])
        await h.hub.start()
        XCTAssertNotNil(h.slot(a.id))
        XCTAssertNil(h.slot(b.id), "no coordinator is built without a token")
        XCTAssertEqual(h.hub.sections[1].status, .authFailed("No token stored for this server"))
        XCTAssertEqual(h.hub.sections[1].sessions, [])
    }

    func testSetEnabledBuildsAndTearsDown() async {
        let a = makeConfig("a", enabled: false)
        let h = HubHarness(configs: [a])
        await h.hub.start()
        XCTAssertNil(h.slot(a.id))
        XCTAssertTrue(h.hub.setEnabled(a.id, true))
        await Task.yield()
        XCTAssertNotNil(h.slot(a.id))
        XCTAssertTrue(h.bookmarks.loadAll()[0].enabled, "persisted")
        let slot = h.slot(a.id)!
        XCTAssertTrue(h.hub.setEnabled(a.id, false))
        XCTAssertTrue(slot.tornDown)
        XCTAssertNil(h.slot(a.id))
        XCTAssertEqual(h.hub.sections[0].status, .disabled)
    }

    func testNinthEnabledIsRefused() async {
        let configs = (1...9).map { makeConfig("s\($0)", enabled: $0 <= 8) }
        let h = HubHarness(configs: configs)
        await h.hub.start()
        XCTAssertEqual(h.hub.enabledCount, 8)
        XCTAssertFalse(h.hub.setEnabled(configs[8].id, true), "cap is 8 (D12)")
        XCTAssertFalse(h.bookmarks.loadAll()[8].enabled)
    }

    func testIdentityIsMirroredOntoTheBookmark() async {
        let a = makeConfig("a")
        let h = HubHarness(configs: [a])
        await h.hub.start()
        let identity = ServerIdentity(id: UUID(), name: "studio")
        h.slot(a.id)!.serverIdentity = identity
        await Task.yield()
        let saved = h.bookmarks.loadAll()[0]
        XCTAssertEqual(saved.instanceId, identity.id)
        XCTAssertEqual(saved.displayName, "studio")
        XCTAssertEqual(h.hub.sections[0].config.displayName, "studio")
    }

    func testStopTearsDownEverySlot() async {
        let a = makeConfig("a"), b = makeConfig("b")
        let h = HubHarness(configs: [a, b])
        await h.hub.start()
        let sa = h.slot(a.id)!, sb = h.slot(b.id)!
        h.hub.stop()
        XCTAssertTrue(sa.tornDown && sb.tornDown)
        XCTAssertNil(h.slot(a.id))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | grep -v "^error: SwiftCompile" | head -3`
Expected: `cannot find type 'ServerSlotCoordinating'`.

- [ ] **Step 3: The slot protocol**

Create `Sources/CodeRelayClient/Hub/ServerSlotCoordinating.swift`:

```swift
import Foundation
import Combine
import CodeRelayKit

/// What the multi-server hub needs from one per-server coordinator (spec §7).
///
/// `SharedSessionCoordinator` conforms; tests use a scripted fake. The surface
/// is deliberately the coordinator's EXISTING API plus the four Phase-1 hooks
/// (`detachActive`, `serverIdentity`, `isAuthRejected`, `start`) — the hub must
/// not grow a parallel session model.
@MainActor
public protocol ServerSlotCoordinating: AnyObject, ObservableObject {
    var sessions: [SessionInfo] { get }
    var activeSessions: [SessionInfo] { get }
    var activeSessionId: UUID? { get }
    var isRecovering: Bool { get }
    var recoveryFailed: Bool { get }
    var isAuthRejected: Bool { get }
    var isPerformingHandshake: Bool { get }
    var connectionState: RelayConnection.ConnectionState { get }
    var serverIdentity: ServerIdentity? { get }
    var sessionLoadPhase: SessionLoadPhase? { get }
    var activityCoordinator: ActivityCoordinator { get }

    func start() async
    func switchToSession(id: UUID) async
    func createNewSession() async
    func detachActive() async
    func handleForegroundTransition(userInitiated: Bool) async
    func triggerUserRecovery()
    func tearDown()
    func syncPushRegistration(pushEnabled: Bool, notifyOnFinished: Bool) async
    func attachRemoteSession(id: UUID, serverName: String?) async
    func fetchSessions(force: Bool) async
}

/// Keychain lookup the hub uses to build a coordinator. `AuthManager` conforms.
public protocol TokenProviding: AnyObject {
    func loadToken(for connectionId: UUID) throws -> String?
}

extension AuthManager: TokenProviding {}
```

In `SharedSessionCoordinator.swift` line 9 change `open class SharedSessionCoordinator: ObservableObject, SessionCoordinating {` to `open class SharedSessionCoordinator: ObservableObject, SessionCoordinating, ServerSlotCoordinating {`. Every requirement already exists after Task 3 (`fetchSessions(force:)` has a default argument; a protocol requirement without one is satisfied by it).

If `AuthManager` is a `final class` the extension compiles as written; if it is a struct, change `TokenProviding` to drop `AnyObject`.

- [ ] **Step 4: Sections, status, aggregate**

Create `Sources/CodeRelayClient/Hub/ServerSection.swift`:

```swift
import Foundation
import CodeRelayKit

/// Where one server stands, for its sidebar header (spec §7.2, §8.1).
public enum ServerSectionStatus: Equatable, Sendable {
    case connecting
    case live
    case reconnecting
    case offline
    case authFailed(String)
    case disabled

    public var isLive: Bool { self == .live }

    /// Pure derivation from a coordinator's published flags. Order matters:
    /// a rejected token beats everything (recovery will not retry it), recovery
    /// beats the raw socket state, and a connected socket still mid-handshake
    /// is "connecting" rather than "live".
    public static func derive(enabled: Bool,
                              connection: RelayConnection.ConnectionState,
                              isRecovering: Bool,
                              isPerformingHandshake: Bool,
                              authRejected: Bool,
                              recoveryFailed: Bool) -> ServerSectionStatus {
        guard enabled else { return .disabled }
        if authRejected { return .authFailed("Token rejected by the relay") }
        if isRecovering { return .reconnecting }
        switch connection {
        case .connected: return isPerformingHandshake ? .connecting : .live
        case .connecting: return .connecting
        default: return .offline
        }
    }
}

/// One server's slice of the sidebar.
public struct ServerSection: Identifiable, Equatable {
    public var id: UUID { config.id }
    public var config: ConnectionConfig
    public var status: ServerSectionStatus
    /// Live list while `status.isLive`; the last live list otherwise (D4).
    public var sessions: [SessionInfo]
    public var isCached: Bool
    public var rollups: [WorkspaceRollup]
    public var awaitingInput: Int
    public var isCollapsed: Bool

    /// Header label: the relay's own name when learned, else the bookmark name.
    public var title: String { config.displayName ?? config.name }
}

/// Cross-server counts for badges and the menu bar (spec §7.6). Cached
/// sections contribute nothing.
public struct HubAggregate: Equatable {
    public var liveServers = 0
    public var totalServers = 0
    public var enabledServers = 0
    public var sessionsAwaitingInput = 0
    public var workingSessions = 0
    public init() {}
}
```

- [ ] **Step 5: The hub's own persistence**

Create `Sources/CodeRelayClient/Hub/HubStateStore.swift`:

```swift
import Foundation
import CodeRelayKit

/// UserDefaults for the hub itself (spec §9): the global active ref, which
/// server sections are collapsed, and the one-time migration flag. Everything
/// per server stays in that server's `SessionOwnershipStore` namespace.
@MainActor
public final class HubStateStore {
    public let activeRefKey: String
    public let collapsedServersKey: String
    public let migratedKey: String
    private let defaults: UserDefaults

    public init(keyPrefix: String, deviceId: String, defaults: UserDefaults = .standard) {
        activeRefKey = "\(keyPrefix).hub.activeRef.\(deviceId)"
        collapsedServersKey = "\(keyPrefix).hub.collapsedServers.\(deviceId)"
        migratedKey = "\(keyPrefix).hub.migrated"
        self.defaults = defaults
    }

    public func loadActiveRef() -> SessionRef? {
        guard let data = defaults.data(forKey: activeRefKey) else { return nil }
        return try? JSONDecoder().decode(SessionRef.self, from: data)
    }

    public func saveActiveRef(_ ref: SessionRef?) {
        if let ref, let data = try? JSONEncoder().encode(ref) {
            defaults.set(data, forKey: activeRefKey)
        } else {
            defaults.removeObject(forKey: activeRefKey)
        }
    }

    public func loadCollapsedServers() -> Set<UUID> {
        Set((defaults.stringArray(forKey: collapsedServersKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    public func saveCollapsedServers(_ ids: Set<UUID>) {
        defaults.set(ids.map(\.uuidString).sorted(), forKey: collapsedServersKey)
    }

    public var isMigrated: Bool { defaults.bool(forKey: migratedKey) }
    public func markMigrated() { defaults.set(true, forKey: migratedKey) }
}
```

- [ ] **Step 6: The hub**

Create `Sources/CodeRelayClient/Hub/ServerHub.swift`:

```swift
import Foundation
import Combine
import CodeRelayKit
import os.log

private let hubLog = Logger(subsystem: "com.coderelay.client", category: "hub")

/// One workspace across several relays (multi-server spec §7).
///
/// Owns one per-server coordinator (`Slot`) for every ENABLED bookmark, merges
/// their published state into `sections`, and holds the single global active
/// session. It never talks to the network, runs recovery, or holds terminal
/// views — those stay in the coordinators, unchanged.
@MainActor
public final class ServerHub<Slot: ServerSlotCoordinating>: ObservableObject {

    public typealias Factory = @MainActor (ConnectionConfig, String) -> Slot

    // MARK: - Published state

    @Published public private(set) var sections: [ServerSection] = []
    @Published public private(set) var activeRef: SessionRef?
    @Published public private(set) var aggregate = HubAggregate()
    /// User-facing notices the hub produces (deep-link enable, cap refusal…).
    @Published public var notice: String?

    public var activeCoordinator: Slot? { activeRef.flatMap { slots[$0.serverId] } }
    public var enabledCount: Int { bookmarks.filter(\.enabled).count }

    // MARK: - Dependencies

    private let bookmarkStore: SavedConnectionStore
    private let tokens: TokenProviding
    private let stateStore: HubStateStore
    private let keyPrefix: String
    private let factory: Factory
    private let maxEnabled: Int
    private let stagger: Duration
    private let sleep: @MainActor (Duration) async -> Void

    private(set) var bookmarks: [ConnectionConfig] = []
    private var slots: [UUID: Slot] = [:]
    private var slotSubscriptions: [UUID: AnyCancellable] = [:]
    private var cachedSessions: [UUID: [SessionInfo]] = [:]
    private var missingToken: Set<UUID> = []
    private var collapsedServers: Set<UUID> = []
    private var started = false

    // Test hooks
    public var onTestEvent: ((String) -> Void)?
    public private(set) var recordedSleeps: [Duration] = []

    public init(bookmarks: SavedConnectionStore,
                tokens: TokenProviding,
                stateStore: HubStateStore,
                keyPrefix: String,
                factory: @escaping Factory,
                maxEnabled: Int = 8,
                stagger: Duration = .milliseconds(150),
                sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.bookmarkStore = bookmarks
        self.tokens = tokens
        self.stateStore = stateStore
        self.keyPrefix = keyPrefix
        self.factory = factory
        self.maxEnabled = maxEnabled
        self.stagger = stagger
        self.sleep = sleep
        self.collapsedServers = stateStore.loadCollapsedServers()
    }

    // MARK: - Lifecycle (spec §7.3)

    /// Builds a coordinator per enabled bookmark, staggered, then publishes.
    public func start() async {
        guard !started else { return }
        started = true
        bookmarks = bookmarkStore.loadAll()
        var index = 0
        for config in bookmarks where config.enabled {
            let delay = stagger * index
            recordedSleeps.append(delay)
            await sleep(delay)
            await buildSlot(for: config)
            index += 1
        }
        publish()
    }

    public func stop() {
        for (_, slot) in slots { slot.tearDown() }
        slots.removeAll()
        slotSubscriptions.removeAll()
        started = false
        publish()
    }

    /// Re-reads the bookmark store (after add/edit/delete on the management
    /// window) and reconciles coordinators: new enabled bookmarks get one,
    /// removed ones are torn down, edited ones (host/port/TLS) are rebuilt.
    public func reloadBookmarks() {
        let fresh = bookmarkStore.loadAll()
        let freshById = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        for (id, slot) in slots {
            guard let now = freshById[id], now.enabled else { tearDownSlot(id); continue }
            if let old = bookmarks.first(where: { $0.id == id }),
               old.host != now.host || old.port != now.port || old.useTLS != now.useTLS {
                tearDownSlot(id)
            }
            _ = slot
        }
        bookmarks = fresh
        Task { [weak self] in
            guard let self else { return }
            for config in fresh where config.enabled && self.slots[config.id] == nil {
                await self.buildSlot(for: config)
            }
            self.publish()
        }
        publish()
    }

    /// Flips a bookmark's `enabled` flag and persists it. Returns false when the
    /// cap refuses (D12) — the caller shows `notice`.
    @discardableResult
    public func setEnabled(_ serverId: UUID, _ enabled: Bool) -> Bool {
        guard var config = bookmarks.first(where: { $0.id == serverId }) else { return false }
        if enabled, config.enabled == false, enabledCount >= maxEnabled {
            notice = "Up to \(maxEnabled) servers can be enabled at once. Disable one first."
            return false
        }
        config.enabled = enabled
        bookmarkStore.add(config)
        bookmarks = bookmarkStore.loadAll()
        if enabled {
            Task { [weak self] in await self?.buildSlot(for: config); self?.publish() }
        } else {
            tearDownSlot(serverId)
            publish()
        }
        return true
    }

    public func slot(for serverId: UUID) -> Slot? { slots[serverId] }

    // MARK: - Slots

    private func buildSlot(for config: ConnectionConfig) async {
        guard slots[config.id] == nil else { return }
        let token: String?
        do { token = try tokens.loadToken(for: config.id) } catch { token = nil }
        guard let token else {
            missingToken.insert(config.id)
            hubLog.error("No token for bookmark \(config.id.uuidString, privacy: .public); section marked authFailed")
            publish()
            return
        }
        missingToken.remove(config.id)
        let slot = factory(config, token)
        slots[config.id] = slot
        slotSubscriptions[config.id] = slot.objectWillChange.sink { [weak self] _ in
            // Published values change AFTER willChange; read them on the next turn.
            DispatchQueue.main.async { self?.slotDidChange(config.id) }
        }
        onTestEvent?("start:\(config.name)")
        await slot.start()
        publish()
    }

    private func tearDownSlot(_ serverId: UUID) {
        if activeRef?.serverId == serverId {
            let slot = slots[serverId]
            activeRef = nil
            stateStore.saveActiveRef(nil)
            Task { await slot?.detachActive() }
        }
        slots[serverId]?.tearDown()
        slots[serverId] = nil
        slotSubscriptions[serverId] = nil
    }

    private func slotDidChange(_ serverId: UUID) {
        guard let slot = slots[serverId] else { return }
        // Learn the relay's identity once and persist it on the bookmark (§5.2).
        if let identity = slot.serverIdentity,
           var config = bookmarks.first(where: { $0.id == serverId }),
           config.instanceId != identity.id || config.displayName != identity.name {
            config.instanceId = identity.id
            config.displayName = identity.name.isEmpty ? nil : identity.name
            bookmarkStore.add(config)
            bookmarks = bookmarkStore.loadAll()
        }
        publish()
    }

    // MARK: - Publishing (spec §7.2, §7.6)

    func publish() {
        var agg = HubAggregate()
        agg.totalServers = bookmarks.count
        agg.enabledServers = enabledCount
        sections = bookmarks.map { config in
            let slot = slots[config.id]
            var status = ServerSectionStatus.derive(
                enabled: config.enabled,
                connection: slot?.connectionState ?? .disconnected,
                isRecovering: slot?.isRecovering ?? false,
                isPerformingHandshake: slot?.isPerformingHandshake ?? false,
                authRejected: slot?.isAuthRejected ?? false,
                recoveryFailed: slot?.recoveryFailed ?? false)
            if config.enabled, missingToken.contains(config.id) {
                status = .authFailed("No token stored for this server")
            }
            let live = slot?.activeSessions ?? []
            if status.isLive {
                cachedSessions[config.id] = live
            }
            let shown = status.isLive ? live : (cachedSessions[config.id] ?? [])
            let rollups = slot?.activityCoordinator.rollups(for: shown) ?? []
            let awaiting = status.isLive ? (slot?.activityCoordinator.sessionsAwaitingInput.count ?? 0) : 0
            if status.isLive {
                agg.liveServers += 1
                agg.sessionsAwaitingInput += awaiting
                agg.workingSessions += rollups.reduce(0) { $0 + $1.workingCount }
            }
            return ServerSection(config: config, status: status, sessions: shown,
                                 isCached: !status.isLive, rollups: rollups,
                                 awaitingInput: awaiting, isCollapsed: collapsedServers.contains(config.id))
        }
        aggregate = agg
    }

    // MARK: - Collapse (per device)

    public func setCollapsed(_ serverId: UUID, _ collapsed: Bool) {
        if collapsed { collapsedServers.insert(serverId) } else { collapsedServers.remove(serverId) }
        stateStore.saveCollapsedServers(collapsedServers)
        publish()
    }
}
```

`WorkspaceRollup.workingCount` — check `Sources/CodeRelayKit/Models/WorkspaceRollup.swift` for the member that counts working sessions (the Phase 0 exploration listed `attentionCount` and a `state`); if there is no working count, replace `rollups.reduce(0) { $0 + $1.workingCount }` with `shown.filter { $0.agentState == .working }.count` and keep the aggregate field.

`FakeServerSlot.goLive` changes several `@Published` values in a row; each `objectWillChange` schedules a `slotDidChange` on the next main-queue turn, which is why the tests `await Task.yield()` before asserting. If a yield is not enough on the runner, replace the yields in the tests with `await hubSettle()` defined as `try? await Task.sleep(for: .milliseconds(20))`.

- [ ] **Step 7: Run the tests**

Run: `swift test --filter 'ServerHubTests|SharedSessionCoordinatorHubHooksTests' 2>&1 | grep -E "Test Suite '.*Tests' (passed|failed)|Executed [0-9]+ tests|error:"` — Expected: `ServerHubTests` passed, 10 tests.

- [ ] **Step 8: Commit**

```bash
git add Sources/CodeRelayClient/Hub Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift Sources/CodeRelayClient/AuthManager.swift \
  Tests/CodeRelayClientTests/Hub
git commit -m "feat(client): ServerHub — one coordinator per enabled bookmark, sections, status, cap

Spec §7.1–7.3, §7.6, D4, D10–D12. Coordinators are reached through the
ServerSlotCoordinating protocol so hub behaviour is tested with a scripted
fake; SharedSessionCoordinator conforms with no further changes.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Selection, the single-attachment invariant, pending selection and restore

**Files:**
- Modify: `Sources/CodeRelayClient/Hub/ServerHub.swift` (add the `// MARK: - Selection` section and the restore step in `start()`)
- Test: `Tests/CodeRelayClientTests/Hub/ServerHubSelectionTests.swift` (new)

**Interfaces:**
- Produces: `func select(_ ref: SessionRef) async`, `func createSession(on serverId: UUID) async`, `func removeServer(_ serverId: UUID) async`, `var orderedRefs: [SessionRef]` (sidebar order across live and cached sections), `func selectNext() async`, `func selectPrevious() async`, `var pendingSelection: [UUID: UUID]` (serverId → sessionId, internal), `var detachBudget: Duration` (default 3 s, forwarded as the per-call bound).
- Produces: `start()` restores `stateStore.loadActiveRef()` when that server is enabled, by calling `select(ref)` once the slot reports a live list containing the session.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeRelayClientTests/Hub/ServerHubSelectionTests.swift`:

```swift
import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

@MainActor
final class ServerHubSelectionTests: XCTestCase {

    private func liveHub(_ names: [String]) async -> (HubHarness, [ConnectionConfig]) {
        let configs = names.map { makeConfig($0) }
        let h = HubHarness(configs: configs)
        await h.hub.start()
        for c in configs { h.slot(c.id)!.goLive(with: [makeSession(), makeSession()]) }
        await Task.yield()
        return (h, configs)
    }

    func testSelectAcrossServersDetachesPreviousBeforeSwitching() async {
        let (h, cfg) = await liveHub(["a", "b"])
        var log: [String] = []
        h.slot(cfg[0].id)!.log = { log.append($0) }
        h.slot(cfg[1].id)!.log = { log.append($0) }
        let sa = h.slot(cfg[0].id)!.sessions[0].id, sb = h.slot(cfg[1].id)!.sessions[0].id

        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: sa))
        XCTAssertEqual(h.hub.activeRef, SessionRef(serverId: cfg[0].id, sessionId: sa))
        XCTAssertEqual(log, ["switch:a"], "same-server selection never detaches first")

        log.removeAll()
        await h.hub.select(SessionRef(serverId: cfg[1].id, sessionId: sb))
        XCTAssertEqual(log, ["detach:a", "switch:b"], "D9: detach on the old server strictly before the attach on the new one")
        XCTAssertEqual(h.hub.activeRef?.serverId, cfg[1].id)
        XCTAssertNil(h.slot(cfg[0].id)!.activeSessionId, "at most one coordinator holds a selection")
        XCTAssertEqual(h.state.loadActiveRef(), h.hub.activeRef, "persisted for restore (§9)")
    }

    func testSelectingTheActiveRefIsANoOp() async {
        let (h, cfg) = await liveHub(["a"])
        let s = h.slot(cfg[0].id)!.sessions[0].id
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: s))
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: s))
        XCTAssertEqual(h.slot(cfg[0].id)!.switchedTo.count, 1)
    }

    func testSelectWithinOneServerDoesNotDetachThroughTheHub() async {
        let (h, cfg) = await liveHub(["a"])
        let slot = h.slot(cfg[0].id)!
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: slot.sessions[0].id))
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: slot.sessions[1].id))
        XCTAssertEqual(slot.detachActiveCount, 0, "the coordinator's own switchToSession handles same-server detach")
        XCTAssertEqual(slot.switchedTo.count, 2)
    }

    func testHungDetachDoesNotBlockTheSwitch() async {
        let (h, cfg) = await liveHub(["a", "b"])
        h.hub.detachBudget = .milliseconds(100)
        let a = h.slot(cfg[0].id)!, b = h.slot(cfg[1].id)!
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: a.sessions[0].id))
        a.detachHangs = true
        let started = ContinuousClock.now
        await h.hub.select(SessionRef(serverId: cfg[1].id, sessionId: b.sessions[0].id))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertEqual(b.switchedTo.count, 1, "the new server was attached despite the stuck detach")
        a.detachGate?.resume()
    }

    func testSelectingOfflineRowIsAppliedWhenServerReturns() async {
        let (h, cfg) = await liveHub(["a"])
        let slot = h.slot(cfg[0].id)!
        let target = slot.sessions[1].id
        slot.goOffline(); slot.sessions = []
        await Task.yield()
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: target))
        XCTAssertEqual(slot.userRecoveryCount, 1, "selecting a cached row is the reconnect gesture (D4)")
        XCTAssertEqual(slot.switchedTo, [], "nothing attached while offline")
        XCTAssertEqual(h.hub.activeRef, SessionRef(serverId: cfg[0].id, sessionId: target), "the UI shows the selection immediately")

        slot.goLive(with: [makeSession(target)])
        await Task.yield(); await Task.yield()
        XCTAssertEqual(slot.switchedTo, [target], "pending selection applied once the list proves the session still exists")
    }

    func testPendingSelectionForAVanishedSessionIsDropped() async {
        let (h, cfg) = await liveHub(["a"])
        let slot = h.slot(cfg[0].id)!
        let target = slot.sessions[1].id
        slot.goOffline(); slot.sessions = []; await Task.yield()
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: target))
        slot.goLive(with: [makeSession()])      // server restarted: new ids
        await Task.yield(); await Task.yield()
        XCTAssertEqual(slot.switchedTo, [])
        XCTAssertNil(h.hub.activeRef, "a selection the server no longer lists is cleared (§12)")
        XCTAssertEqual(h.hub.notice, "That session has ended")
    }

    func testCreateSessionOnAnotherServerDetachesFirst() async {
        let (h, cfg) = await liveHub(["a", "b"])
        var log: [String] = []
        h.slot(cfg[0].id)!.log = { log.append($0) }; h.slot(cfg[1].id)!.log = { log.append($0) }
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: h.slot(cfg[0].id)!.sessions[0].id))
        log.removeAll()
        await h.hub.createSession(on: cfg[1].id)
        XCTAssertEqual(log, ["detach:a", "create:b"])
        XCTAssertEqual(h.hub.activeRef?.serverId, cfg[1].id)
        XCTAssertEqual(h.hub.activeRef?.sessionId, h.slot(cfg[1].id)!.activeSessionId)
    }

    func testRemoveActiveServerDetachesAndClearsActiveRef() async {
        let (h, cfg) = await liveHub(["a", "b"])
        let a = h.slot(cfg[0].id)!
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: a.sessions[0].id))
        await h.hub.removeServer(cfg[0].id)
        XCTAssertEqual(a.detachActiveCount, 1)
        XCTAssertTrue(a.tornDown)
        XCTAssertNil(h.hub.activeRef)
        XCTAssertNil(h.state.loadActiveRef())
        XCTAssertEqual(h.bookmarks.loadAll().map(\.id), [cfg[1].id])
        XCTAssertNil(h.tokens.tokens[cfg[0].id], "token deleted with the bookmark")
    }

    func testOrderedRefsAndNextPreviousWrapAcrossSections() async {
        let (h, cfg) = await liveHub(["a", "b"])
        let refs = h.hub.orderedRefs
        XCTAssertEqual(refs.count, 4)
        XCTAssertEqual(refs.map(\.serverId), [cfg[0].id, cfg[0].id, cfg[1].id, cfg[1].id])
        await h.hub.select(refs[1])
        await h.hub.selectNext()
        XCTAssertEqual(h.hub.activeRef, refs[2], "next crosses the section boundary")
        await h.hub.selectPrevious(); await h.hub.selectPrevious(); await h.hub.selectPrevious()
        XCTAssertEqual(h.hub.activeRef, refs[3], "previous wraps around")
    }

    func testStartRestoresThePersistedRefOnceItsServerListsIt() async {
        let a = makeConfig("a")
        let keep = UUID()
        let h = HubHarness(configs: [a])
        h.state.saveActiveRef(SessionRef(serverId: a.id, sessionId: keep))
        await h.hub.start()
        XCTAssertEqual(h.hub.activeRef, SessionRef(serverId: a.id, sessionId: keep), "shown immediately as cached selection")
        h.slot(a.id)!.goLive(with: [makeSession(keep)])
        await Task.yield(); await Task.yield()
        XCTAssertEqual(h.slot(a.id)!.switchedTo, [keep])
    }

    func testStartDropsAPersistedRefWhoseServerIsDisabled() async {
        let a = makeConfig("a", enabled: false)
        let h = HubHarness(configs: [a])
        h.state.saveActiveRef(SessionRef(serverId: a.id, sessionId: UUID()))
        await h.hub.start()
        XCTAssertNil(h.hub.activeRef)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | grep -v "^error: SwiftCompile" | head -3` — Expected: `no member 'select'`.

- [ ] **Step 3: Implement selection**

In `Sources/CodeRelayClient/Hub/ServerHub.swift` add stored state next to `collapsedServers`:

```swift
    /// serverId → sessionId chosen while that server was not live; applied by
    /// `slotDidChange` once a live list proves the session still exists (D4).
    private(set) var pendingSelection: [UUID: UUID] = [:]
    /// Forwarded to the previous coordinator's `detachActive` bound (§7.5).
    public var detachBudget: Duration = .seconds(3)
```

Append this section before `// MARK: - Collapse (per device)`:

```swift
    // MARK: - Selection (spec §7.5)

    /// Every row the sidebar shows, in sidebar order (live and cached sections),
    /// for keyboard next/previous across section boundaries.
    public var orderedRefs: [SessionRef] {
        sections.flatMap { section in
            section.sessions.map { SessionRef(serverId: section.id, sessionId: $0.id) }
        }
    }

    /// Makes `ref` the one attached session. Same server → the coordinator's own
    /// `switchToSession` (which detaches the previous session itself). Different
    /// server → `detachActive()` on the previous coordinator, bounded, THEN the
    /// attach. Offline server → remember the choice and trigger its recovery.
    public func select(_ ref: SessionRef) async {
        guard let section = sections.first(where: { $0.id == ref.serverId }) else { return }
        if activeRef == ref { return }
        let previous = activeRef
        activeRef = ref
        stateStore.saveActiveRef(ref)
        onTestEvent?("select:\(ref.serverId.uuidString.prefix(4))")

        if let previous, previous.serverId != ref.serverId, let from = slots[previous.serverId] {
            await detachBounded(from)
        }
        guard let to = slots[ref.serverId] else { return }
        if section.status.isLive {
            pendingSelection[ref.serverId] = nil
            await to.switchToSession(id: ref.sessionId)
        } else {
            pendingSelection[ref.serverId] = ref.sessionId
            to.triggerUserRecovery()
        }
        publish()
    }

    /// New session on `serverId`; detaches on any other server first (§7.5).
    public func createSession(on serverId: UUID) async {
        guard let to = slots[serverId] else { return }
        if let previous = activeRef, previous.serverId != serverId, let from = slots[previous.serverId] {
            await detachBounded(from)
        }
        await to.createNewSession()
        if let id = to.activeSessionId {
            activeRef = SessionRef(serverId: serverId, sessionId: id)
            stateStore.saveActiveRef(activeRef)
        }
        publish()
    }

    public func selectNext() async { await step(by: 1) }
    public func selectPrevious() async { await step(by: -1) }

    private func step(by delta: Int) async {
        let refs = orderedRefs
        guard refs.count > 1, let current = activeRef, let index = refs.firstIndex(of: current) else { return }
        let next = (index + delta + refs.count) % refs.count
        await select(refs[next])
    }

    /// Deletes a bookmark: detach if it is active, tear down, forget its token
    /// and its ownership namespace (§7.3, §11).
    public func removeServer(_ serverId: UUID) async {
        if activeRef?.serverId == serverId, let slot = slots[serverId] {
            activeRef = nil
            stateStore.saveActiveRef(nil)
            await detachBounded(slot)
        }
        tearDownSlot(serverId)
        bookmarkStore.delete(id: serverId)
        (tokens as? TokenDeleting)?.deleteTokenIgnoringErrors(for: serverId)
        bookmarks = bookmarkStore.loadAll()
        cachedSessions[serverId] = nil
        pendingSelection[serverId] = nil
        publish()
    }

    private func detachBounded(_ slot: Slot) async {
        let budget = detachBudget
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in await slot.detachActive() }
            group.addTask { try? await Task.sleep(for: budget) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Called from `slotDidChange` after `publish()`: apply or drop a pending
    /// selection once the server is live again.
    private func applyPendingSelection(for serverId: UUID) {
        guard let wanted = pendingSelection[serverId],
              let slot = slots[serverId],
              let section = sections.first(where: { $0.id == serverId }), section.status.isLive else { return }
        pendingSelection[serverId] = nil
        if slot.activeSessions.contains(where: { $0.id == wanted }) {
            Task { await slot.switchToSession(id: wanted); self.publish() }
        } else {
            if activeRef == SessionRef(serverId: serverId, sessionId: wanted) {
                activeRef = nil
                stateStore.saveActiveRef(nil)
            }
            notice = "That session has ended"
            publish()
        }
    }
```

Add the token-deletion seam to `ServerSlotCoordinating.swift`:

```swift
/// Optional companion to `TokenProviding` for bookmark deletion.
public protocol TokenDeleting: AnyObject {
    func deleteTokenIgnoringErrors(for connectionId: UUID)
}

extension AuthManager: TokenDeleting {
    public func deleteTokenIgnoringErrors(for connectionId: UUID) { try? deleteToken(for: connectionId) }
}
```

and make the test's `FakeTokens` conform: `extension HubHarness.FakeTokens: TokenDeleting { func deleteTokenIgnoringErrors(for id: UUID) { tokens[id] = nil } }` (add inside `FakeServerSlot.swift`).

In `slotDidChange(_:)` add, as the last line after `publish()`: `applyPendingSelection(for: serverId)`.

In `start()`, after `bookmarks = bookmarkStore.loadAll()` add the restore:

```swift
        // F3 across servers (§9): restore the last active ref as a cached
        // selection; `applyPendingSelection` attaches it once that server's
        // live list proves the session still exists.
        if let saved = stateStore.loadActiveRef(),
           bookmarks.contains(where: { $0.id == saved.serverId && $0.enabled }) {
            activeRef = saved
            pendingSelection[saved.serverId] = saved.sessionId
        } else {
            stateStore.saveActiveRef(nil)
        }
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter 'ServerHubSelectionTests|ServerHubTests' 2>&1 | grep -E "Test Suite '.*Tests' (passed|failed)|Executed [0-9]+ tests|error:"` — Expected: both passed; `ServerHubSelectionTests` 11 tests.

If `testHungDetachDoesNotBlockTheSwitch` flakes on the `FakeServerSlot.detachHangs` continuation, the fake's `detachActive` must store the continuation before awaiting (it does) and the test resumes it at the end so no continuation leaks.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeRelayClient/Hub Tests/CodeRelayClientTests/Hub
git commit -m "feat(client): hub selection — one attachment across servers, pending selection, restore

Cross-server select awaits a bounded detachActive() on the previous
coordinator before attaching; a cached row selection becomes the reconnect
gesture and is applied when the server returns (spec §7.5, §9, §12).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Fan-out, push registration, deep-link routing, duplicate detection

**Files:**
- Modify: `Sources/CodeRelayClient/Hub/ServerHub.swift` (add `// MARK: - Fan-out` and `// MARK: - Deep links`), `Sources/CodeRelayClient/Hub/ServerSection.swift` (add `isDuplicateInstance`)
- Test: `Tests/CodeRelayClientTests/Hub/ServerHubRoutingTests.swift` (new)

**Interfaces:**
- Produces: `func handleForegroundTransition(userInitiated: Bool) async` (staggered fan-out to live slots), `func triggerUserRecovery(serverId: UUID? = nil)`, `func syncPushRegistration(pushEnabled: Bool, notifyOnFinished: Bool) async` (fan-out), `func handleDeepLink(_ link: SessionDeepLink) async -> DeepLinkOutcome` with `enum DeepLinkOutcome: Equatable { case selected(SessionRef), enabledAndSelected(SessionRef), attachingRemote(serverId: UUID), notFound(serverName: String?) }`.
- Produces: `ServerSection.isDuplicateInstance: Bool` — true when another bookmark has the same `instanceId`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeRelayClientTests/Hub/ServerHubRoutingTests.swift`:

```swift
import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

@MainActor
final class ServerHubRoutingTests: XCTestCase {

    private func liveHub(_ names: [String]) async -> (HubHarness, [ConnectionConfig]) {
        let configs = names.map { makeConfig($0) }
        let h = HubHarness(configs: configs)
        await h.hub.start()
        for c in configs { h.slot(c.id)!.goLive(with: [makeSession()]) }
        await Task.yield()
        return (h, configs)
    }

    // MARK: Fan-out (spec §7.3, D10)

    func testForegroundFansOutToLiveSlotsWithStagger() async {
        let (h, cfg) = await liveHub(["a", "b", "c"])
        h.slot(cfg[1].id)!.goOffline(); await Task.yield()
        h.hub.recordedSleepsReset()
        await h.hub.handleForegroundTransition(userInitiated: true)
        XCTAssertEqual(h.slot(cfg[0].id)!.foregroundCount, 1)
        XCTAssertEqual(h.slot(cfg[1].id)!.foregroundCount, 1, "offline servers get the transition too — it is how they come back")
        XCTAssertEqual(h.slot(cfg[2].id)!.foregroundCount, 1)
        XCTAssertEqual(h.hub.recordedSleeps, [.zero, .milliseconds(150), .milliseconds(300)])
    }

    func testUserRecoveryTargetsOneServerOrAll() async {
        let (h, cfg) = await liveHub(["a", "b"])
        h.hub.triggerUserRecovery(serverId: cfg[1].id)
        XCTAssertEqual(h.slot(cfg[0].id)!.userRecoveryCount, 0)
        XCTAssertEqual(h.slot(cfg[1].id)!.userRecoveryCount, 1)
        h.hub.triggerUserRecovery()
        XCTAssertEqual(h.slot(cfg[0].id)!.userRecoveryCount, 1)
        XCTAssertEqual(h.slot(cfg[1].id)!.userRecoveryCount, 2)
    }

    func testPushSyncReachesEverySlot() async {
        let (h, cfg) = await liveHub(["a", "b"])
        await h.hub.syncPushRegistration(pushEnabled: true, notifyOnFinished: false)
        XCTAssertEqual(h.slot(cfg[0].id)!.pushSyncs.count, 1)
        XCTAssertEqual(h.slot(cfg[1].id)!.pushSyncs.count, 1)
        XCTAssertEqual(h.slot(cfg[1].id)!.pushSyncs[0].0, true)
    }

    // MARK: Deep links (spec §10)

    func testInstanceIdRoutesToThatServer() async {
        let (h, cfg) = await liveHub(["a", "b"])
        let identity = ServerIdentity(id: UUID(), name: "b-relay")
        h.slot(cfg[1].id)!.serverIdentity = identity; await Task.yield()
        let target = h.slot(cfg[1].id)!.sessions[0].id
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: target, serverInstanceId: identity.id))
        XCTAssertEqual(outcome, .selected(SessionRef(serverId: cfg[1].id, sessionId: target)))
        XCTAssertEqual(h.slot(cfg[1].id)!.switchedTo, [target])
        XCTAssertEqual(h.slot(cfg[0].id)!.switchedTo, [])
    }

    func testInstanceIdOnADisabledBookmarkEnablesItWithANotice() async {
        let a = makeConfig("a"), b = makeConfig("b", enabled: false)
        var bWithIdentity = b
        let identity = ServerIdentity(id: UUID(), name: "b-relay")
        bWithIdentity.instanceId = identity.id
        let h = HubHarness(configs: [a, bWithIdentity])
        await h.hub.start()
        let target = UUID()
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: target, serverInstanceId: identity.id))
        XCTAssertEqual(outcome, .enabledAndSelected(SessionRef(serverId: b.id, sessionId: target)))
        XCTAssertTrue(h.bookmarks.loadAll()[1].enabled)
        XCTAssertEqual(h.hub.notice, "Enabled b to open this session")
        XCTAssertEqual(h.hub.activeRef, SessionRef(serverId: b.id, sessionId: target), "shown as a pending selection until b lists it")
    }

    func testUniqueSessionIdAcrossLiveSectionsRoutesWithoutServerHint() async {
        let (h, cfg) = await liveHub(["a", "b"])
        let target = h.slot(cfg[0].id)!.sessions[0].id
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: target))
        XCTAssertEqual(outcome, .selected(SessionRef(serverId: cfg[0].id, sessionId: target)))
    }

    func testUnknownSessionWithOneServerFallsBackToRemoteAttach() async {
        let (h, cfg) = await liveHub(["a"])
        let target = UUID()
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: target))
        XCTAssertEqual(outcome, .attachingRemote(serverId: cfg[0].id))
        XCTAssertEqual(h.slot(cfg[0].id)!.remoteAttaches, [target])
    }

    func testUnknownSessionWithSeveralServersIsNotFound() async {
        let (h, _) = await liveHub(["a", "b"])
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: UUID()))
        XCTAssertEqual(outcome, .notFound(serverName: nil))
        XCTAssertEqual(h.hub.notice, "Session not found on any enabled server")
    }

    func testUnknownInstanceIdNamesNothingButStillSearchesSessions() async {
        let (h, cfg) = await liveHub(["a"])
        let target = h.slot(cfg[0].id)!.sessions[0].id
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: target, serverInstanceId: UUID()))
        XCTAssertEqual(outcome, .selected(SessionRef(serverId: cfg[0].id, sessionId: target)),
                       "an instance id we have not learned yet must not block a session we can see")
    }

    func testDeepLinkBeforeStartIsQueued() async {
        let a = makeConfig("a")
        let h = HubHarness(configs: [a])
        let target = UUID()
        let early = Task { await h.hub.handleDeepLink(SessionDeepLink(sessionId: target)) }
        await h.hub.start()
        let outcome = await early.value
        XCTAssertEqual(outcome, .attachingRemote(serverId: a.id))
    }

    // MARK: Duplicates (spec §10, §12)

    func testDuplicateInstanceIdIsFlagged() async {
        let (h, cfg) = await liveHub(["a", "b"])
        let identity = ServerIdentity(id: UUID(), name: "same")
        h.slot(cfg[0].id)!.serverIdentity = identity
        h.slot(cfg[1].id)!.serverIdentity = identity
        await Task.yield()
        XCTAssertTrue(h.hub.sections[0].isDuplicateInstance)
        XCTAssertTrue(h.hub.sections[1].isDuplicateInstance)
        let target = h.slot(cfg[0].id)!.sessions[0].id
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: target, serverInstanceId: identity.id))
        XCTAssertEqual(outcome, .selected(SessionRef(serverId: cfg[0].id, sessionId: target)), "first enabled bookmark wins")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | grep -v "^error: SwiftCompile" | head -3` — Expected: `no member 'handleDeepLink'`.

- [ ] **Step 3: Implement**

In `ServerSection.swift` add to `ServerSection`: `public var isDuplicateInstance: Bool = false` (after `isCollapsed`).

In `ServerHub.swift`:

Add state: `private var startGate: [CheckedContinuation<Void, Never>] = []` next to `started`, and a public test helper `public func recordedSleepsReset() { recordedSleeps.removeAll() }`.

At the end of `start()` (after `publish()`) add `for c in startGate { c.resume() }; startGate.removeAll()`.

In `publish()`, after computing `sections`, mark duplicates:

```swift
        var seen: [UUID: Int] = [:]
        for s in sections { if let id = s.config.instanceId { seen[id, default: 0] += 1 } }
        for i in sections.indices {
            if let id = sections[i].config.instanceId { sections[i].isDuplicateInstance = seen[id, default: 0] > 1 }
        }
```

Append before `// MARK: - Collapse (per device)`:

```swift
    // MARK: - Fan-out (spec §7.3, D10)

    /// Foreground / wake / network-restored: every coordinator gets the event,
    /// staggered so N servers do not reconnect in lockstep. Offline ones are
    /// included — this is how they come back.
    public func handleForegroundTransition(userInitiated: Bool) async {
        var index = 0
        for config in bookmarks where config.enabled {
            guard let slot = slots[config.id] else { continue }
            let delay = stagger * index
            recordedSleeps.append(delay)
            await sleep(delay)
            await slot.handleForegroundTransition(userInitiated: userInitiated)
            index += 1
        }
        publish()
    }

    /// One server (the section's Retry) or all of them (menu bar / shortcut).
    public func triggerUserRecovery(serverId: UUID? = nil) {
        if let serverId { slots[serverId]?.triggerUserRecovery(); return }
        for (_, slot) in slots { slot.triggerUserRecovery() }
    }

    /// Push registration is per relay: each coordinator decides and sends for
    /// its own socket (spec §10).
    public func syncPushRegistration(pushEnabled: Bool, notifyOnFinished: Bool) async {
        for (_, slot) in slots {
            await slot.syncPushRegistration(pushEnabled: pushEnabled, notifyOnFinished: notifyOnFinished)
        }
    }

    // MARK: - Deep links (spec §10)

    public enum DeepLinkOutcome: Equatable {
        case selected(SessionRef)
        case enabledAndSelected(SessionRef)
        case attachingRemote(serverId: UUID)
        case notFound(serverName: String?)
    }

    /// Routing precedence: instance id → unique session across live sections →
    /// single enabled server's cross-device attach → not found. A link that
    /// arrives before `start()` finished waits for it.
    public func handleDeepLink(_ link: SessionDeepLink) async -> DeepLinkOutcome {
        if !started || slots.isEmpty && bookmarks.contains(where: \.enabled) {
            await withCheckedContinuation { startGate.append($0) }
        }
        // 1. The relay named itself.
        if let instanceId = link.serverInstanceId,
           let config = bookmarks.first(where: { $0.instanceId == instanceId }) {
            let ref = SessionRef(serverId: config.id, sessionId: link.sessionId)
            if !config.enabled {
                if setEnabled(config.id, true) {
                    notice = "Enabled \(config.displayName ?? config.name) to open this session"
                    activeRef = ref
                    stateStore.saveActiveRef(ref)
                    pendingSelection[config.id] = link.sessionId
                    publish()
                    return .enabledAndSelected(ref)
                }
                return .notFound(serverName: config.displayName ?? config.name)
            }
            await select(ref)
            return .selected(ref)
        }
        // 2. Exactly one live section lists the session.
        let hits = sections.filter { $0.status.isLive && $0.sessions.contains(where: { $0.id == link.sessionId }) }
        if hits.count == 1 {
            let ref = SessionRef(serverId: hits[0].id, sessionId: link.sessionId)
            await select(ref)
            return .selected(ref)
        }
        // 3. One enabled server: the pre-hub cross-device attach.
        let enabled = bookmarks.filter(\.enabled)
        if enabled.count == 1, let slot = slots[enabled[0].id] {
            if let previous = activeRef, previous.serverId != enabled[0].id, let from = slots[previous.serverId] {
                await detachBounded(from)
            }
            await slot.attachRemoteSession(id: link.sessionId, serverName: nil)
            if let id = slot.activeSessionId {
                activeRef = SessionRef(serverId: enabled[0].id, sessionId: id)
                stateStore.saveActiveRef(activeRef)
            }
            publish()
            return .attachingRemote(serverId: enabled[0].id)
        }
        // 4. Nothing to route to.
        notice = "Session not found on any enabled server"
        return .notFound(serverName: nil)
    }
```

The start-gate condition reads: wait when `start()` has not run yet, or when it has run but no slot exists while some bookmark is enabled (a start still building). Parenthesise it as `if !started || (slots.isEmpty && bookmarks.contains(where: \.enabled))` to satisfy the compiler's precedence warning.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter 'ServerHubRoutingTests|ServerHubSelectionTests|ServerHubTests' 2>&1 | grep -E "Test Suite '.*Tests' (passed|failed)|Executed [0-9]+ tests|error:"` — Expected: all passed; routing 11 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeRelayClient/Hub Tests/CodeRelayClientTests/Hub
git commit -m "feat(client): hub fan-out, per-server push sync, deep-link routing, duplicate flagging

Spec §7.3, §10, §12: staggered foreground fan-out; instance id → unique
session → single-server remote attach → not found; a disabled bookmark
named by a push tap is enabled on demand with a notice.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: One-time migration from the single-server layout

**Files:**
- Create: `Sources/CodeRelayClient/Hub/HubMigration.swift`
- Modify: `Sources/CodeRelayClient/Hub/ServerHub.swift` (`start()` runs it first)
- Test: `Tests/CodeRelayClientTests/Hub/HubMigrationTests.swift` (new)

**Interfaces:**
- Produces: `enum HubMigration { @discardableResult static func run(defaults: UserDefaults, keyPrefix: String, deviceId: String, bookmarks: SavedConnectionStore, lastServerIdKey: String, stateStore: HubStateStore) -> Bool }` — returns true when it migrated, false when already done. Idempotent.
- Produces: `ServerHub.init` gains `lastServerIdKey: String?` (nil → no migration; macOS passes `"com.clauderelay.mac.lastServerId"`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeRelayClientTests/Hub/HubMigrationTests.swift`:

```swift
import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

@MainActor
final class HubMigrationTests: XCTestCase {

    private struct Env {
        let defaults: UserDefaults
        let bookmarks: SavedConnectionStore
        let state: HubStateStore
        let prefix = "mig.test"
        let device = "dev-1"
        let lastKey = "mig.test.lastServerId"
    }

    private func env(configs: [ConnectionConfig], lastServerId: String?) -> Env {
        let suite = "HubMigrationTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let bookmarks = SavedConnectionStore(key: "mig.bookmarks", defaults: d)
        bookmarks.saveAll(configs)
        if let lastServerId { d.set(lastServerId, forKey: "mig.test.lastServerId") }
        return Env(defaults: d, bookmarks: bookmarks, state: HubStateStore(keyPrefix: "mig.test", deviceId: "dev-1", defaults: d))
    }

    private func seedLegacy(_ e: Env, names: [UUID: String], active: UUID?) {
        let legacy = SessionOwnershipStore(keyPrefix: e.prefix, deviceId: e.device, defaults: e.defaults)
        legacy.saveNames(names)
        legacy.saveAgents([names.keys.first!: "claude"])
        legacy.saveActiveSession(active)
        legacy.saveCollapsedGroups(["/repo"])
    }

    private func run(_ e: Env) -> Bool {
        HubMigration.run(defaults: e.defaults, keyPrefix: e.prefix, deviceId: e.device,
                         bookmarks: e.bookmarks, lastServerIdKey: e.lastKey, stateStore: e.state)
    }

    func testLegacyStateMovesIntoTheLastServersNamespace() {
        let a = makeConfig("a"), b = makeConfig("b")
        let e = env(configs: [a, b], lastServerId: a.id.uuidString)
        let sid = UUID()
        seedLegacy(e, names: [sid: "alpha"], active: sid)

        XCTAssertTrue(run(e))

        let migrated = SessionOwnershipStore(keyPrefix: "\(e.prefix).\(a.id.uuidString)", deviceId: e.device, defaults: e.defaults)
        XCTAssertEqual(migrated.loadNames()[sid], "alpha")
        XCTAssertEqual(migrated.loadAgents()[sid], "claude")
        XCTAssertEqual(migrated.loadCollapsedGroups(), ["/repo"])
        XCTAssertEqual(e.state.loadActiveRef(), SessionRef(serverId: a.id, sessionId: sid))
        let saved = e.bookmarks.loadAll()
        XCTAssertTrue(saved[0].enabled, "the last-used server stays on (G8)")
        XCTAssertFalse(saved[1].enabled, "every other bookmark is off until the user enables it")
        // Legacy keys are gone.
        let legacy = SessionOwnershipStore(keyPrefix: e.prefix, deviceId: e.device, defaults: e.defaults)
        XCTAssertTrue(legacy.loadNames().isEmpty)
        XCTAssertNil(legacy.loadActiveSession())
        XCTAssertNil(e.defaults.object(forKey: e.lastKey), "lastServerId retired")
        XCTAssertTrue(e.state.isMigrated)
    }

    func testMigrationIsIdempotent() {
        let a = makeConfig("a")
        let e = env(configs: [a], lastServerId: a.id.uuidString)
        seedLegacy(e, names: [UUID(): "x"], active: nil)
        XCTAssertTrue(run(e))
        _ = e.bookmarks.add({ var c = e.bookmarks.loadAll()[0]; c.enabled = false; return c }())
        XCTAssertFalse(run(e), "second run is a no-op")
        XCTAssertFalse(e.bookmarks.loadAll()[0].enabled, "a second run must not re-enable anything")
    }

    func testMigrationWithMissingLastServer() {
        let a = makeConfig("a"), b = makeConfig("b")
        let e = env(configs: [a, b], lastServerId: UUID().uuidString)   // deleted bookmark
        seedLegacy(e, names: [UUID(): "orphan"], active: nil)
        XCTAssertTrue(run(e))
        XCTAssertEqual(e.bookmarks.loadAll().map(\.enabled), [false, false])
        for c in [a, b] {
            let ns = SessionOwnershipStore(keyPrefix: "\(e.prefix).\(c.id.uuidString)", deviceId: e.device, defaults: e.defaults)
            XCTAssertTrue(ns.loadNames().isEmpty, "orphaned maps are dropped, not guessed onto a server")
        }
        XCTAssertNil(e.state.loadActiveRef())
    }

    func testSingleBookmarkIsEnabledEvenWithoutALastServer() {
        let a = makeConfig("a")
        let e = env(configs: [a], lastServerId: nil)
        XCTAssertTrue(run(e))
        XCTAssertTrue(e.bookmarks.loadAll()[0].enabled)
    }

    func testNoBookmarksStillMarksMigrated() {
        let e = env(configs: [], lastServerId: nil)
        XCTAssertTrue(run(e))
        XCTAssertTrue(e.state.isMigrated)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | grep -v "^error: SwiftCompile" | head -2` — Expected: `cannot find 'HubMigration'`.

- [ ] **Step 3: Implement**

Create `Sources/CodeRelayClient/Hub/HubMigration.swift`:

```swift
import Foundation
import CodeRelayKit

/// One-time move from the single-server layout to per-server namespaces
/// (multi-server spec §9). Runs before the first `ServerHub.start()`.
///
/// Only the bookmark the old `lastServerId` names keeps `enabled = true`, so
/// the upgrade looks exactly like the previous build (G8); turning on other
/// servers is an explicit action on the management screen. Legacy maps that
/// belong to no surviving bookmark are dropped rather than guessed onto one.
@MainActor
public enum HubMigration {

    @discardableResult
    public static func run(defaults: UserDefaults,
                           keyPrefix: String,
                           deviceId: String,
                           bookmarks: SavedConnectionStore,
                           lastServerIdKey: String,
                           stateStore: HubStateStore) -> Bool {
        guard !stateStore.isMigrated else { return false }
        var all = bookmarks.loadAll()
        let lastId = defaults.string(forKey: lastServerIdKey).flatMap(UUID.init(uuidString:))
        let keep: UUID? = {
            if let lastId, all.contains(where: { $0.id == lastId }) { return lastId }
            if all.count == 1 { return all[0].id }
            return nil
        }()

        let legacy = SessionOwnershipStore(keyPrefix: keyPrefix, deviceId: deviceId, defaults: defaults)
        if let keep {
            let target = SessionOwnershipStore(keyPrefix: "\(keyPrefix).\(keep.uuidString)",
                                               deviceId: deviceId, defaults: defaults)
            target.saveNames(legacy.loadNames())
            target.saveAgents(legacy.loadAgents())
            target.saveCollapsedGroups(legacy.loadCollapsedGroups())
            if let active = legacy.loadActiveSession() {
                stateStore.saveActiveRef(SessionRef(serverId: keep, sessionId: active))
            }
        }
        for key in [legacy.namesKey, legacy.agentsKey, legacy.activeSessionKey, legacy.collapsedGroupsKey, lastServerIdKey] {
            defaults.removeObject(forKey: key)
        }
        for i in all.indices { all[i].enabled = (all[i].id == keep) }
        bookmarks.saveAll(all)
        stateStore.markMigrated()
        return true
    }
}
```

In `ServerHub.swift`: add `private let lastServerIdKey: String?` and `private let defaults: UserDefaults`; extend `init` with `lastServerIdKey: String? = nil, defaults: UserDefaults = .standard` (before `factory`), storing both. At the top of `start()`, before `bookmarks = bookmarkStore.loadAll()`:

```swift
        if let lastServerIdKey {
            HubMigration.run(defaults: defaults, keyPrefix: keyPrefix, deviceId: DeviceIdentifier().currentID,
                             bookmarks: bookmarkStore, lastServerIdKey: lastServerIdKey, stateStore: stateStore)
        }
```

The hub's `HubStateStore` and the coordinators' namespaces must use the same `deviceId` the migration used (`DeviceIdentifier().currentID`), which is what `SharedSessionCoordinator.init` already uses.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter 'HubMigrationTests|ServerHubTests|ServerHubSelectionTests|ServerHubRoutingTests|SessionOwnershipStoreTests' 2>&1 | grep -E "Test Suite '.*Tests' (passed|failed)|error:"` — Expected: all passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeRelayClient/Hub Tests/CodeRelayClientTests/Hub
git commit -m "feat(client): one-time migration into per-server namespaces (spec §9)

Only the previously last-used bookmark stays enabled; legacy maps move
into its namespace; orphaned maps and lastServerId are dropped.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: macOS — the hub owns the workspace

**Files:**
- Modify: `CodeRelayMac/ViewModels/SessionCoordinator.swift:34-50` (init + start), `CodeRelayMac/ViewModels/MenuBarViewModel.swift` (registry holds the hub), `CodeRelayMac/Views/MainWindow.swift:1-100` (hub root), `CodeRelayMac/CodeRelayMacApp.swift:70-85` (deep link via hub), `CodeRelayMac/Helpers/AppCommands.swift` (focused hub), `CodeRelayMac/AppDelegate.swift` (no change; wake stays a notification)
- Create: `CodeRelayMac/ViewModels/MacServerHub.swift`
- Test: `CodeRelayMacTests/MacServerHubTests.swift` (new)

**Interfaces:**
- Produces: `typealias MacServerHub = ServerHub<SessionCoordinator>`; `enum MacServerHubFactory { static func make(defaults: UserDefaults = .standard) -> MacServerHub }` using `CodeRelayMacApp.savedConnections`, `AuthManager.shared`, key prefix `SessionCoordinator.keyPrefix`, `lastServerIdKey: "com.clauderelay.mac.lastServerId"`, factory `{ config, token in SessionCoordinator(config: config, token: token, ownershipKeyPrefix: "\(SessionCoordinator.keyPrefix).\(config.id.uuidString)") }`.
- Produces: `SessionCoordinator.init(config:token:ownershipKeyPrefix:)`; `override func start() async` (connect + handshake; **no** per-coordinator wake/network observers — the hub fans out).
- Produces: `ActiveCoordinatorRegistry.register(hub:)` / `clear()`; `var hub: MacServerHub?`; `var coordinator: SessionCoordinator? { hub?.activeCoordinator }` kept as a computed forwarder so `MenuBarDropdown`/`AppCommands` keep compiling in this task.
- Produces: `FocusedValues.serverHub: MacServerHub?`.

- [ ] **Step 1: Write the failing test**

Create `CodeRelayMacTests/MacServerHubTests.swift`:

```swift
import XCTest
import CodeRelayClient
// Module is c99-sanitized from PRODUCT_NAME "Code[Relay]" — see project.yml.
@testable import Code_Relay_

@MainActor
final class MacServerHubTests: XCTestCase {

    func testFactoryNamespacesEachCoordinatorByBookmark() {
        let suite = "MacServerHubTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let config = ConnectionConfig(name: "studio", host: "studio.local")
        let coordinator = MacServerHubFactory.makeCoordinator(config: config, token: "t", defaults: defaults)
        XCTAssertEqual(coordinator.ownershipKeyPrefixForTest, "com.clauderelay.mac.\(config.id.uuidString)")
    }

    func testStartDoesNotInstallPerCoordinatorWakeObservers() async {
        // The hub fans wake/network events out with a stagger; a coordinator that
        // also listened would reconnect twice per wake (D10).
        let config = ConnectionConfig(name: "studio", host: "127.0.0.1", port: 1)
        let coordinator = SessionCoordinator(config: config, token: "t", ownershipKeyPrefix: "mac.test.\(UUID().uuidString)")
        XCTAssertEqual(coordinator.recoveryObserverCountForTest, 0)
        coordinator.tearDown()
    }

    func testRegistryExposesTheActiveCoordinatorOfTheHub() {
        let registry = ActiveCoordinatorRegistry.shared
        registry.clear()
        XCTAssertNil(registry.hub)
        XCTAssertNil(registry.coordinator)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:" | head -3` — Expected: `cannot find 'MacServerHubFactory'`.

- [ ] **Step 3: `SessionCoordinator` becomes a hub slot**

In `CodeRelayMac/ViewModels/SessionCoordinator.swift` replace the init (lines 34-42) with:

```swift
    init(config: ConnectionConfig, token: String, ownershipKeyPrefix: String? = nil) {
        self.config = config
        super.init(connection: RelayConnection(), token: token, ownershipKeyPrefix: ownershipKeyPrefix)
        stateObserver = connection.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isConnected = (state == .connected)
            }
    }
```

Replace `func start() async {` with `override func start() async {` and delete the line `registerRecoveryObservers()` inside it. Delete `registerRecoveryObservers()` and `unregisterRecoveryObservers()` entirely, delete `private var recoveryObservers`, and make `tearDown()` just `override func tearDown() { super.tearDown() }`. Add the test hook: `var recoveryObserverCountForTest: Int { 0 }` is pointless once the array is gone — instead delete `testStartDoesNotInstallPerCoordinatorWakeObservers`'s assertion line and keep the test as a construction smoke test (`XCTAssertNotNil(coordinator)`). The wake and network-restored notifications are now consumed by the hub owner in `MainWindow` (Step 5).

- [ ] **Step 4: Factory and registry**

Create `CodeRelayMac/ViewModels/MacServerHub.swift`:

```swift
import Foundation
import CodeRelayClient

typealias MacServerHub = ServerHub<SessionCoordinator>

@MainActor
enum MacServerHubFactory {
    static let lastServerIdKey = "com.clauderelay.mac.lastServerId"

    static func makeCoordinator(config: ConnectionConfig, token: String,
                                defaults: UserDefaults = .standard) -> SessionCoordinator {
        SessionCoordinator(config: config, token: token,
                           ownershipKeyPrefix: "\(SessionCoordinator.keyPrefix).\(config.id.uuidString)")
    }

    static func make(defaults: UserDefaults = .standard) -> MacServerHub {
        ServerHub(
            bookmarks: CodeRelayMacApp.savedConnections,
            tokens: AuthManager.shared,
            stateStore: HubStateStore(keyPrefix: SessionCoordinator.keyPrefix,
                                      deviceId: DeviceIdentifier().currentID, defaults: defaults),
            keyPrefix: SessionCoordinator.keyPrefix,
            lastServerIdKey: lastServerIdKey,
            defaults: defaults,
            factory: { config, token in makeCoordinator(config: config, token: token, defaults: defaults) })
    }
}
```

(`ownershipKeyPrefix` is passed, `defaults` is `.standard` for coordinators — the `defaults` parameter exists so a test can build one; drop it from `makeCoordinator`'s body if `SessionCoordinator` has no defaults parameter, which it does not — the base init's `defaults` stays `.standard`.)

In `MenuBarViewModel.swift` replace `ActiveCoordinatorRegistry` (lines 8-26) with:

```swift
@MainActor
final class ActiveCoordinatorRegistry: ObservableObject {
    static let shared = ActiveCoordinatorRegistry()

    /// The one hub the main window owns. Menu bar and app commands read the
    /// active coordinator through it.
    @Published private(set) var hub: MacServerHub?

    /// Convenience for callers that act on the attached session's relay.
    var coordinator: SessionCoordinator? { hub?.activeCoordinator }
    var serverName: String? {
        guard let hub, let ref = hub.activeRef else { return nil }
        return hub.sections.first(where: { $0.id == ref.serverId })?.title
    }

    private init() {}

    func register(hub: MacServerHub) { self.hub = hub }
    func clear() { hub = nil }
}
```

`MenuBarViewModel.observeRegistry()` iterates `registry.$coordinator.values` today — change it to `registry.$hub.values` and, inside, follow `hub.activeCoordinator` the same way it followed the coordinator (Task 10 then regroups the list by server; this task keeps the dropdown compiling by passing `hub?.activeCoordinator` into the existing `followCoordinator`, and re-running that whenever `hub.$activeRef` changes — add a fourth task in `followCoordinator`'s place: `for await _ in hub.$activeRef.values { if let c = hub.activeCoordinator { self.followCoordinator(c) } }`).

In `CodeRelayMac/Helpers/AppCommands.swift` add after the existing focused value key:

```swift
struct ServerHubKey: FocusedValueKey {
    typealias Value = MacServerHub
}

extension FocusedValues {
    var serverHub: MacServerHub? {
        get { self[ServerHubKey.self] }
        set { self[ServerHubKey.self] = newValue }
    }
}
```

and in `AppCommands` add `@FocusedValue(\.serverHub) var hub: MacServerHub?`. The existing `coordinator` focused value keeps working because `MainWindow` publishes `hub.activeCoordinator` into it (Step 5). The "Next/Previous Session" commands (find them in the same file) call `coordinator.switchToNextSession()` / `switchToPreviousSession()` — change those two bodies to `Task { await hub?.selectNext() }` / `Task { await hub?.selectPrevious() }` so they cross section boundaries.

- [ ] **Step 5: `MainWindow` roots on the hub**

Replace the `MainWindow` struct (lines 4-96) with:

```swift
struct MainWindow: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var hub = MacServerHubFactory.make()

    var body: some View {
        WorkspaceView(hub: hub, settings: settings)
            .background(.black)
            .task {
                ActiveCoordinatorRegistry.shared.register(hub: hub)
                await hub.start()
                await syncPush()
            }
            .onDisappear {
                hub.stop()
                ActiveCoordinatorRegistry.shared.clear()
            }
            // Wake and network-restored fan out through the hub with a stagger
            // (D10); coordinators no longer listen on their own.
            .onReceive(NotificationCenter.default.publisher(for: SleepWakeObserver.systemDidWake)) { _ in
                Task { await hub.handleForegroundTransition(userInitiated: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NetworkMonitor.connectivityRestored)) { _ in
                Task { await hub.handleForegroundTransition(userInitiated: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showServerList)) { _ in
                hub.isShowingServerList = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .connectToServer)) { notification in
                // A freshly paired bookmark: it is saved enabled, so reloading
                // the store builds its coordinator.
                if notification.object is ConnectionConfig { hub.reloadBookmarks() }
            }
            .onReceive(PushTokenBridge.shared.$deviceToken) { _ in Task { await syncPush() } }
            .onChange(of: settings.pushNotificationsEnabled) { _, _ in Task { await syncPush() } }
            .onChange(of: settings.pushNotifyOnFinished) { _, _ in Task { await syncPush() } }
            .preferredColorScheme(.dark)
            .focusedValue(\.sessionCoordinator, hub.activeCoordinator)
            .focusedValue(\.serverHub, hub)
    }

    private func syncPush() async {
        await hub.syncPushRegistration(
            pushEnabled: settings.pushNotificationsEnabled,
            notifyOnFinished: settings.pushNotifyOnFinished)
    }
}
```

`hub.isShowingServerList` is a new `@Published public var isShowingServerList = false` on `ServerHub` (UI-only flag, added in `ServerHub.swift` next to `notice`). `AppDelegate` already creates the `NetworkMonitor` that posts `connectivityRestored`, and the coordinators' own `startNetworkRecovery()` is no longer called on macOS (it lived in the deleted `registerRecoveryObservers`).

Replace `WorkspaceView`'s header (lines 98-108) so it takes the hub and derives the active coordinator:

```swift
private struct WorkspaceView: View {
    @ObservedObject var hub: MacServerHub
    @ObservedObject var settings: AppSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showQRPopover = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var reloadCover: Double = 0

    private var coordinator: SessionCoordinator? { hub.activeCoordinator }
```

Then, in the body: the sidebar becomes `HubSidebarView(hub: hub)` (Task 9); the detail `if let activeId = coordinator.activeSessionId` becomes `if let coordinator, let activeId = coordinator.activeSessionId`, and every `coordinator.` inside the detail/toolbar/alerts is guarded the same way — wrap the detail `VStack` body and the toolbar/alert modifiers in a helper `@ViewBuilder private func detail(for coordinator: SessionCoordinator?) -> some View` that renders the existing content when non-nil and the existing "No session selected" placeholder (whose New Session button becomes `Task { await hub.createSession(on: firstEnabled) }` with `firstEnabled = hub.sections.first(where: { $0.status.isLive })?.id`) when nil. The sheets bound to `$coordinator.showQRScanner`, `$coordinator.isRecovering`, `$coordinator.sessionAttachFailed`, `$coordinator.connectionTimedOut` move onto an inner `ActiveCoordinatorModifiers(coordinator:)` view that takes a non-optional `@ObservedObject var coordinator: SessionCoordinator`, applied with `.overlay { if let coordinator { ActiveCoordinatorModifiers(coordinator: coordinator) } }` — SwiftUI cannot bind through an optional. The `RecoverySheet` therefore only ever shows for the **active** server (spec §8.1). Add a `.sheet(isPresented: $hub.isShowingServerList) { NavigationStack { ServerListWindow(hub: hub) } }` (Task 10 gives `ServerListWindow` the hub parameter; until then pass nothing and keep the old signature compiling by leaving the sheet out of this task).

Add a hub-level toast for `hub.notice`: `.overlay(alignment: .top) { if let notice = hub.notice { Text(notice).padding(8).background(.ultraThinMaterial, in: Capsule()).padding(.top, 8).task { try? await Task.sleep(for: .seconds(4)); hub.notice = nil } } }`.

- [ ] **Step 6: Deep links through the hub**

In `CodeRelayMacApp.swift` replace the session-link body (from Task 1) with:

```swift
        guard let link = SessionDeepLink(url: url) else { return }
        Task { @MainActor in
            guard let hub = ActiveCoordinatorRegistry.shared.hub else { return }
            _ = await hub.handleDeepLink(link)
        }
```

- [ ] **Step 7: Build and run the Mac tests**

Run the macOS build gate, then `xcodebuild test … -only-testing:CodeRelayMacTests` — Expected: `BUILD SUCCEEDED`, test bundle passed (existing `SessionNavigationTests`, `MenuBarActivityTests` included).

- [ ] **Step 8: Commit**

```bash
git add CodeRelayMac/ViewModels/SessionCoordinator.swift CodeRelayMac/ViewModels/MacServerHub.swift CodeRelayMac/ViewModels/MenuBarViewModel.swift \
  CodeRelayMac/Views/MainWindow.swift CodeRelayMac/CodeRelayMacApp.swift CodeRelayMac/Helpers/AppCommands.swift \
  Sources/CodeRelayClient/Hub/ServerHub.swift CodeRelayMacTests/MacServerHubTests.swift
git commit -m "feat(mac): the ServerHub owns the workspace

MainWindow builds one hub, which builds a coordinator per enabled
bookmark; wake/network events and push sync fan out through it; deep
links route through it; the registry exposes the hub to the menu bar.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: macOS sidebar — one section per server

**Files:**
- Create: `Sources/CodeRelayClient/Views/ServerSectionHeader.swift`
- Create: `CodeRelayMac/Views/HubSidebarView.swift`
- Modify: `CodeRelayMac/Views/SessionSidebarView.swift` (becomes the per-server rows; keep its row/rollup helpers)
- Test: `Tests/CodeRelayClientTests/ServerSectionHeaderTests.swift` (new, model-level), `CodeRelayMacTests/HubSidebarOrderTests.swift` (new)

**Interfaces:**
- Produces: `ServerSectionHeaderModel(section: ServerSection, showsServerName: Bool)` with `title`, `subtitle: String?` ("offline · last seen 3 min ago", "reconnecting…", "token rejected", "disabled"), `dotColor`, `badge: Int`; and `ServerSectionHeader(model:isCollapsed:onToggle:onRetry:onNew:)` view.
- Produces: `HubSidebarView(hub: MacServerHub)` — `List(selection: Binding<SessionRef?>)` over `hub.sections`; rows tagged `SessionRef`; cached rows at 50 % opacity; per-section New button; Retry on offline/authFailed headers (`authFailed` → opens the server window on that bookmark).

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeRelayClientTests/ServerSectionHeaderTests.swift`:

```swift
import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

final class ServerSectionHeaderTests: XCTestCase {
    private func section(_ status: ServerSectionStatus, name: String = "Studio", displayName: String? = nil,
                         awaiting: Int = 0) -> ServerSection {
        var c = ConnectionConfig(name: name, host: "h"); c.displayName = displayName
        return ServerSection(config: c, status: status, sessions: [], isCached: !status.isLive,
                             rollups: [], awaitingInput: awaiting, isCollapsed: false)
    }

    func testTitlePrefersTheRelaysOwnName() {
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.live, displayName: "studio-mac")).title, "studio-mac")
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.live)).title, "Studio")
    }

    func testSubtitlesAndColours() {
        XCTAssertNil(ServerSectionHeaderModel(section: section(.live)).subtitle)
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.connecting)).subtitle, "connecting…")
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.reconnecting)).subtitle, "reconnecting…")
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.offline)).subtitle, "offline")
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.authFailed("Token rejected"))).subtitle, "Token rejected")
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.disabled)).subtitle, "disabled")
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.live)).dotColor, .green)
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.reconnecting)).dotColor, .orange)
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.offline)).dotColor, .red)
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.authFailed("x"))).dotColor, .orange)
    }

    func testBadgeIsTheAwaitingCountOnlyWhenLive() {
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.live, awaiting: 3)).badge, 3)
        XCTAssertEqual(ServerSectionHeaderModel(section: section(.offline, awaiting: 3)).badge, 0)
    }

    func testRetryIsOfferedForOfflineAndAuthFailedOnly() {
        XCTAssertTrue(ServerSectionHeaderModel(section: section(.offline)).offersRetry)
        XCTAssertTrue(ServerSectionHeaderModel(section: section(.authFailed("x"))).offersRetry)
        XCTAssertFalse(ServerSectionHeaderModel(section: section(.live)).offersRetry)
        XCTAssertFalse(ServerSectionHeaderModel(section: section(.reconnecting)).offersRetry)
    }
}
```

Create `CodeRelayMacTests/HubSidebarOrderTests.swift`:

```swift
import XCTest
import CodeRelayClient
import CodeRelayKit
@testable import Code_Relay_

final class HubSidebarOrderTests: XCTestCase {
    func testRowsFollowSectionOrderAndKeepServerIdentity() {
        let a = ConnectionConfig(name: "a", host: "a"), b = ConnectionConfig(name: "b", host: "b")
        let s1 = UUID(), s2 = UUID()
        let sections = [
            ServerSection(config: a, status: .live, sessions: [SessionInfo(id: s1, state: .activeDetached, tokenId: "t", createdAt: Date(), cols: 80, rows: 24)],
                          isCached: false, rollups: [], awaitingInput: 0, isCollapsed: false),
            ServerSection(config: b, status: .offline, sessions: [SessionInfo(id: s2, state: .activeDetached, tokenId: "t", createdAt: Date(), cols: 80, rows: 24)],
                          isCached: true, rollups: [], awaitingInput: 0, isCollapsed: false)
        ]
        let rows = HubSidebarView.rows(for: sections)
        XCTAssertEqual(rows.map(\.ref), [SessionRef(serverId: a.id, sessionId: s1), SessionRef(serverId: b.id, sessionId: s2)])
        XCTAssertEqual(rows.map(\.isCached), [false, true])
    }

    func testCollapsedSectionContributesNoRows() {
        var c = ConnectionConfig(name: "a", host: "a")
        c.enabled = true
        let section = ServerSection(config: c, status: .live,
                                    sessions: [SessionInfo(id: UUID(), state: .activeDetached, tokenId: "t", createdAt: Date(), cols: 80, rows: 24)],
                                    isCached: false, rollups: [], awaitingInput: 0, isCollapsed: true)
        XCTAssertTrue(HubSidebarView.rows(for: [section]).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | grep -v "^error: SwiftCompile" | head -2` — Expected: `cannot find 'ServerSectionHeaderModel'`.

- [ ] **Step 3: Shared header model and view**

Create `Sources/CodeRelayClient/Views/ServerSectionHeader.swift`:

```swift
import SwiftUI
import CodeRelayKit

/// Pure presentation of a server section's header line (spec §8.1), shared by
/// the macOS sidebar now and the iOS one in Plan 2.
public struct ServerSectionHeaderModel: Equatable {
    public let title: String
    public let subtitle: String?
    public let dotColor: Color
    public let badge: Int
    public let offersRetry: Bool
    public let isDuplicate: Bool

    public init(section: ServerSection) {
        title = section.title
        switch section.status {
        case .live:            subtitle = nil;              dotColor = .green;  offersRetry = false
        case .connecting:      subtitle = "connecting…";    dotColor = .orange; offersRetry = false
        case .reconnecting:    subtitle = "reconnecting…";  dotColor = .orange; offersRetry = false
        case .offline:         subtitle = "offline";        dotColor = .red;    offersRetry = true
        case .authFailed(let m): subtitle = m;              dotColor = .orange; offersRetry = true
        case .disabled:        subtitle = "disabled";       dotColor = .gray;   offersRetry = false
        }
        badge = section.status.isLive ? section.awaitingInput : 0
        isDuplicate = section.isDuplicateInstance
    }
}

/// The section header row: name, status dot, subtitle, attention badge,
/// Retry (offline / token rejected), New, collapse chevron.
public struct ServerSectionHeader: View {
    private let model: ServerSectionHeaderModel
    private let isCollapsed: Bool
    private let onToggle: () -> Void
    private let onRetry: () -> Void
    private let onNew: (() -> Void)?

    public init(model: ServerSectionHeaderModel, isCollapsed: Bool,
                onToggle: @escaping () -> Void, onRetry: @escaping () -> Void, onNew: (() -> Void)?) {
        self.model = model; self.isCollapsed = isCollapsed
        self.onToggle = onToggle; self.onRetry = onRetry; self.onNew = onNew
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Circle().fill(model.dotColor).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.title).font(.system(.caption, design: .rounded, weight: .bold)).lineLimit(1)
                        if let subtitle = model.subtitle {
                            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if model.isDuplicate {
                        Image(systemName: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                            .help("Another bookmark points at this same relay")
                    }
                    Spacer(minLength: 4)
                    if model.badge > 0 {
                        Text("\(model.badge)").font(.caption2.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.85))).foregroundStyle(.white)
                    }
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.offersRetry {
                Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Reconnect")
            } else if let onNew {
                Button(action: onNew) { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("New session on \(model.title)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.title)\(model.subtitle.map { ", \($0)" } ?? "")")
    }
}
```

- [ ] **Step 4: The hub sidebar**

Create `CodeRelayMac/Views/HubSidebarView.swift`:

```swift
import SwiftUI
import CodeRelayClient
import CodeRelayKit

/// One collapsible section per bookmark (spec §8.1/§8.3); inside each, the
/// unchanged workspace tiles and session rows for that server.
struct HubSidebarView: View {
    @ObservedObject var hub: MacServerHub
    @State private var showAttachSheetFor: UUID?

    struct Row: Equatable {
        let ref: SessionRef
        let session: SessionInfo
        let isCached: Bool
    }

    /// Flattened rows in sidebar order, skipping collapsed sections. Pure, for
    /// tests and for keyboard navigation parity with `ServerHub.orderedRefs`.
    static func rows(for sections: [ServerSection]) -> [Row] {
        sections.flatMap { section -> [Row] in
            guard !section.isCollapsed else { return [] }
            return section.sessions.map {
                Row(ref: SessionRef(serverId: section.id, sessionId: $0.id), session: $0, isCached: section.isCached)
            }
        }
    }

    private var selection: Binding<SessionRef?> {
        Binding(get: { hub.activeRef }, set: { ref in if let ref { Task { await hub.select(ref) } } })
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                ForEach(hub.sections) { section in
                    Section {
                        ServerSectionHeader(
                            model: ServerSectionHeaderModel(section: section),
                            isCollapsed: section.isCollapsed,
                            onToggle: { hub.setCollapsed(section.id, !section.isCollapsed) },
                            onRetry: {
                                if case .authFailed = section.status { hub.isShowingServerList = true }
                                else { hub.triggerUserRecovery(serverId: section.id) }
                            },
                            onNew: section.status.isLive ? { Task { await hub.createSession(on: section.id) } } : nil)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                        if !section.isCollapsed, let coordinator = hub.slot(for: section.id) {
                            ServerSessionRows(coordinator: coordinator, section: section)
                        } else if !section.isCollapsed, !section.sessions.isEmpty {
                            // Disabled or token-less bookmark with cached rows: plain, greyed.
                            ForEach(section.sessions, id: \.id) { s in
                                Text(s.name ?? String(s.id.uuidString.prefix(8)))
                                    .foregroundStyle(.secondary)
                                    .tag(SessionRef(serverId: section.id, sessionId: s.id))
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button { hub.isShowingServerList = true } label: { Label("Servers", systemImage: "server.rack") }
                    .buttonStyle(.plain)
                Spacer()
                if let active = hub.activeRef {
                    Button { showAttachSheetFor = active.serverId } label: {
                        Label("Attach", systemImage: "rectangle.connected.to.line.below")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .background(.black)
        .sheet(item: Binding(get: { showAttachSheetFor.map(IdentifiedServer.init) }, set: { showAttachSheetFor = $0?.id })) { item in
            if let coordinator = hub.slot(for: item.id) { AttachRemoteSessionSheet(coordinator: coordinator) }
        }
    }

    private struct IdentifiedServer: Identifiable { let id: UUID }
}
```

Refactor `CodeRelayMac/Views/SessionSidebarView.swift` into the per-server rows view used above: rename the struct to `ServerSessionRows`, add `let section: ServerSection`, remove the outer `VStack`/`ScrollViewReader`/`List`/bottom bar (the hub sidebar owns the List), and emit exactly the content that used to be inside the `List`: `ForEach(coordinator.activityCoordinator.rollups(for: sessions))` with its `Section`/`rollupHeader`/`sessionRow`, where `sessions = section.sessions` (cached when offline) and each `sessionRow(session).tag(session.id)` becomes `.tag(SessionRef(serverId: section.id, sessionId: session.id)).opacity(section.isCached ? 0.5 : 1)`. Keep the rename/terminate alerts and `collapse` state inside `ServerSessionRows` (they are per coordinator). Note `rollups(for:)` on a cached list uses the coordinator's last-known activity, which is what D4 asks for.

- [ ] **Step 5: Build and test**

Run: `swift test --filter ServerSectionHeaderTests 2>&1 | grep -E "Test Suite 'ServerSectionHeaderTests' (passed|failed)"` — Expected: passed.
Run the macOS build gate and the Mac test gate — Expected: `BUILD SUCCEEDED`; `HubSidebarOrderTests` passed.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodeRelayClient/Views/ServerSectionHeader.swift CodeRelayMac/Views/HubSidebarView.swift CodeRelayMac/Views/SessionSidebarView.swift \
  Tests/CodeRelayClientTests/ServerSectionHeaderTests.swift CodeRelayMacTests/HubSidebarOrderTests.swift
git commit -m "feat(mac): sidebar grouped by server with status headers and cached offline rows

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: macOS — server management window, menu bar grouping, settings

**Files:**
- Modify: `CodeRelayMac/Views/ServerListWindow.swift` (whole file), `CodeRelayMac/ViewModels/ServerListViewModel.swift` (whole file), `CodeRelayMac/Views/MenuBarDropdown.swift:25-45` (grouped list), `CodeRelayMac/ViewModels/MenuBarViewModel.swift` (follow the hub's sections), `CodeRelayMac/Views/SettingsView.swift:~235-242` (remove the auto-connect row), `CodeRelayMac/Views/MainWindow.swift` (present `ServerListWindow(hub:)` sheet; toolbar Servers button sets `hub.isShowingServerList`)
- Test: `CodeRelayMacTests/MenuBarGroupingTests.swift` (new); extend `CodeRelayMacTests/MenuBarActivityTests.swift` only if `computeActivityStates` signature changes (it does not)

**Interfaces:**
- Produces: `ServerListWindow(hub: MacServerHub)` — rows show name, address, learned identity, a duplicate warning, and an **Enabled** toggle bound to `hub.setEnabled`; no Connect button; Add/Pair/Edit/Delete call `hub.reloadBookmarks()` / `hub.removeServer(id)`. `ServerListViewModel(hub:)` polls `ServerStatusChecker` only for **disabled** bookmarks (D11).
- Produces: `MenuBarViewModel.groups: [MenuBarGroup]` where `struct MenuBarGroup: Identifiable { let id: UUID; let title: String?; let sessions: [SessionInfo]; let statusColor: Color }` — `title` is nil when exactly one server is enabled (G8); `static func groups(from sections: [ServerSection]) -> [MenuBarGroup]` pure; `connectionColor` = green if the active server is live and none is `authFailed`, orange if any enabled server is reconnecting/connecting/authFailed, red if every enabled server is offline, secondary with none enabled.

- [ ] **Step 1: Write the failing test**

Create `CodeRelayMacTests/MenuBarGroupingTests.swift`:

```swift
import XCTest
import SwiftUI
import CodeRelayClient
import CodeRelayKit
@testable import Code_Relay_

final class MenuBarGroupingTests: XCTestCase {
    private func section(_ name: String, _ status: ServerSectionStatus, enabled: Bool = true, sessions: Int = 1) -> ServerSection {
        var c = ConnectionConfig(name: name, host: name); c.enabled = enabled
        let list = (0..<sessions).map { _ in SessionInfo(id: UUID(), state: .activeDetached, tokenId: "t", createdAt: Date(), cols: 80, rows: 24) }
        return ServerSection(config: c, status: status, sessions: list, isCached: !status.isLive,
                             rollups: [], awaitingInput: 0, isCollapsed: false)
    }

    func testOneEnabledServerHasNoGroupTitle() {
        let groups = MenuBarViewModel.groups(from: [section("a", .live), section("b", .disabled, enabled: false)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0].title, "G8: a one-server user sees no server prefix")
    }

    func testSeveralEnabledServersAreTitledAndKeepOrder() {
        let groups = MenuBarViewModel.groups(from: [section("a", .live), section("b", .offline)])
        XCTAssertEqual(groups.map(\.title), ["a", "b"])
        XCTAssertEqual(groups[1].statusColor, .red)
        XCTAssertEqual(groups[1].sessions.count, 1, "cached rows stay listed")
    }

    func testConnectionColourRules() {
        XCTAssertEqual(MenuBarViewModel.connectionColor(for: [section("a", .live)], activeServerId: nil), .green)
        XCTAssertEqual(MenuBarViewModel.connectionColor(for: [section("a", .live), section("b", .reconnecting)], activeServerId: nil), .orange)
        XCTAssertEqual(MenuBarViewModel.connectionColor(for: [section("a", .offline), section("b", .offline)], activeServerId: nil), .red)
        XCTAssertEqual(MenuBarViewModel.connectionColor(for: [section("a", .disabled, enabled: false)], activeServerId: nil), .secondary)
        XCTAssertEqual(MenuBarViewModel.connectionColor(for: [section("a", .live), section("b", .authFailed("x"))], activeServerId: nil), .orange)
    }

    func testStatusCheckerTargetsOnlyDisabledBookmarks() {
        let a = ConnectionConfig(name: "a", host: "a", enabled: true), b = ConnectionConfig(name: "b", host: "b", enabled: false)
        XCTAssertEqual(ServerListViewModel.pollTargets([a, b]).map(\.id), [b.id])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run the Mac test gate — Expected: `type 'MenuBarViewModel' has no member 'groups'`.

- [ ] **Step 3: Menu bar follows the hub**

In `MenuBarViewModel.swift` add the pure helpers and the published groups:

```swift
struct MenuBarGroup: Identifiable, Equatable {
    let id: UUID
    let title: String?
    let sessions: [SessionInfo]
    let statusColor: Color
}

extension MenuBarViewModel {
    static func groups(from sections: [ServerSection]) -> [MenuBarGroup] {
        let enabled = sections.filter { $0.config.enabled }
        let titled = enabled.count > 1
        return enabled.map { s in
            MenuBarGroup(id: s.id, title: titled ? s.title : nil, sessions: s.sessions,
                         statusColor: ServerSectionHeaderModel(section: s).dotColor)
        }
    }

    static func connectionColor(for sections: [ServerSection], activeServerId: UUID?) -> Color {
        let enabled = sections.filter { $0.config.enabled }
        guard !enabled.isEmpty else { return .secondary }
        if enabled.contains(where: { if case .authFailed = $0.status { return true } else { return false } }) { return .orange }
        if enabled.contains(where: { $0.status == .reconnecting || $0.status == .connecting }) { return .orange }
        if enabled.allSatisfy({ $0.status == .offline }) { return .red }
        if let activeServerId, let active = enabled.first(where: { $0.id == activeServerId }), !active.status.isLive { return .orange }
        return .green
    }
}
```

Add `@Published private(set) var groups: [MenuBarGroup] = []` and, in `observeRegistry`, when a hub appears spawn `for await sections in hub.$sections.values { self.groups = Self.groups(from: sections); self.connectionColor = Self.connectionColor(for: sections, activeServerId: hub.activeRef?.serverId); self.connectionLabel = hub.aggregate.enabledServers > 1 ? "\(hub.aggregate.liveServers)/\(hub.aggregate.enabledServers) servers" : (sections.first(where: { $0.config.enabled })?.title ?? "Not connected") }` alongside the existing active-coordinator follow (which still drives `activityStates`/`agentIds`/`activeSessionId`). Set `activeSessionId` from `hub.$activeRef` (`$0?.sessionId`).

In `MenuBarDropdown.swift` replace the flat `ForEach(viewModel.sessions …)` block with:

```swift
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.groups) { group in
                        if let title = group.title {
                            HStack(spacing: 6) {
                                Circle().fill(group.statusColor).frame(width: 6, height: 6)
                                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
                        }
                        ForEach(group.sessions, id: \.id) { session in
                            SessionMenuRow(
                                session: session,
                                activity: viewModel.activityStates[session.id] ?? .active,
                                agentId: viewModel.agentIds[session.id],
                                isActive: session.id == viewModel.activeSessionId,
                                onSelect: { activate(SessionRef(serverId: group.id, sessionId: session.id)) })
                        }
                    }
                }
```

and change `activate(sessionId:)` to `activate(_ ref: SessionRef)` calling `ActiveCoordinatorRegistry.shared.hub?.select(ref)`. "New Session" → `hub.createSession(on: hub.activeRef?.serverId ?? firstLive)`; "Attach Session..." stays on `hub.activeCoordinator`. Empty-state text: `viewModel.groups.allSatisfy { $0.sessions.isEmpty }`.

- [ ] **Step 4: Management window**

Replace `ServerListViewModel.swift` with:

```swift
import Foundation
import SwiftUI
import CodeRelayClient

/// The server management list (spec §8.1, §11). Enabled bookmarks are live in
/// the hub — their status comes from there. Only disabled bookmarks are probed
/// by the status poller (D11), so no bookmark is ever probed twice.
@MainActor
final class ServerListViewModel: ObservableObject {
    @Published private(set) var connections: [ConnectionConfig] = []
    @Published private(set) var statuses: [UUID: ServerStatus] = [:]
    @Published var selectedConnectionId: UUID?

    private let statusChecker = ServerStatusChecker(interval: 15)

    init() {
        statusChecker.$statuses.assign(to: &$statuses)
        loadConnections()
    }

    static func pollTargets(_ connections: [ConnectionConfig]) -> [ConnectionConfig] {
        connections.filter { !$0.enabled }
    }

    func loadConnections() {
        connections = CodeRelayMacApp.savedConnections.loadAll()
        if selectedConnectionId == nil || !connections.contains(where: { $0.id == selectedConnectionId }) {
            selectedConnectionId = connections.first?.id
        }
        statusChecker.refresh(connections: Self.pollTargets(connections))
    }

    func addOrUpdate(_ connection: ConnectionConfig) {
        _ = CodeRelayMacApp.savedConnections.add(connection)
        loadConnections()
    }

    func stopAllPolling() { statusChecker.stopPolling() }
}
```

(`markAsLastUsed`/`delete` are gone: deletion goes through `hub.removeServer`, and `lastServerId` was retired by the migration.) `ServerStatusChecker.refresh(connections:)` exists (used today); check its name with `grep -n "func refresh" Sources/CodeRelayClient/ViewModels/ServerStatusChecker.swift`.

Replace `ServerListWindow.swift`'s row and footer:

```swift
struct ServerListWindow: View {
    @ObservedObject var hub: MacServerHub
    @StateObject private var viewModel = ServerListViewModel()
    @State private var addEditTarget: AddEditTarget?
    @State private var showDeleteAlert = false
    @State private var deleteTarget: ConnectionConfig?
    @State private var showPairSheet = false

    enum AddEditTarget: Identifiable { /* unchanged */ }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedConnectionId) {
                ForEach(hub.sections) { section in
                    ServerRow(section: section,
                              probe: viewModel.statuses[section.id],
                              onToggle: { on in
                                  if !hub.setEnabled(section.id, on) { /* hub.notice explains the cap */ }
                                  viewModel.loadConnections()
                              })
                    .contextMenu {
                        Button("Edit...") { addEditTarget = .edit(section.config) }
                        Divider()
                        Button("Delete", role: .destructive) { deleteTarget = section.config; showDeleteAlert = true }
                    }
                    .tag(section.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            if let notice = hub.notice {
                Text(notice).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12).padding(.top, 6)
            }
            Divider()
            HStack {
                Button { addEditTarget = .add } label: { Label("Add Server", systemImage: "plus") }
                Button { showPairSheet = true } label: { Label("Pair", systemImage: "qrcode") }
                Spacer()
                Text("\(hub.aggregate.enabledServers) of \(hub.aggregate.totalServers) enabled")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .background(.black)
        .frame(minWidth: 520, minHeight: 360)
        .onDisappear { viewModel.stopAllPolling() }
        .navigationTitle("Servers")
        .toolbarBackground(.black, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .sheet(item: $addEditTarget) { target in
            AddEditServerView(target: target) { newConnection in
                viewModel.addOrUpdate(newConnection)
                hub.reloadBookmarks()
                addEditTarget = nil
            }
        }
        .sheet(isPresented: $showPairSheet) {
            PairWithHostSheet(onPaired: { config in
                viewModel.addOrUpdate(config)      // paired bookmarks are saved enabled
                hub.reloadBookmarks()
            }, prefill: nil)
        }
        .alert("Delete Server?", isPresented: $showDeleteAlert, presenting: deleteTarget) { target in
            Button("Delete", role: .destructive) {
                Task { await hub.removeServer(target.id); viewModel.loadConnections() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("Are you sure you want to delete '\(target.name)'?")
        }
    }
}

private struct ServerRow: View {
    let section: ServerSection
    let probe: ServerStatus?
    let onToggle: (Bool) -> Void

    private var model: ServerSectionHeaderModel { ServerSectionHeaderModel(section: section) }
    private var dotColor: Color {
        if section.config.enabled { return model.dotColor }
        guard let probe else { return .gray }
        if probe.reachability == .invalidToken { return .orange }
        return probe.isLive ? .green : .red
    }

    var body: some View {
        HStack {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(section.title).font(.headline)
                    if section.isDuplicateInstance {
                        Label("Same relay as another bookmark", systemImage: "exclamationmark.triangle")
                            .labelStyle(.iconOnly).foregroundStyle(.orange)
                            .help("Another bookmark points at this same relay")
                    }
                }
                Text("\(section.config.useTLS ? "wss" : "ws")://\(section.config.host):\(section.config.port)")
                    .font(.caption).foregroundStyle(.secondary)
                if let subtitle = model.subtitle, section.config.enabled {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                if let instance = section.config.instanceId {
                    Text("instance \(instance.uuidString.prefix(8))…").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { section.config.enabled }, set: onToggle))
                .toggleStyle(.switch).labelsHidden()
                .help(section.config.enabled ? "Shown in the workspace" : "Enable to show this server's sessions")
        }
        .padding(.vertical, 4)
    }
}
```

In `MainWindow.swift` (Task 8's version) add `.sheet(isPresented: $hub.isShowingServerList) { NavigationStack { ServerListWindow(hub: hub) }.background(.black).presentationBackground(.black) }` and make the toolbar `serversToolbarButton` set `hub.isShowingServerList = true` instead of posting `.showServerList`. `MenuBarDropdown`'s "Servers..." keeps posting `.showServerList`, which `MainWindow` already maps onto the flag.

In `SettingsView.swift`, delete the row that contains `Toggle("", isOn: $settings.autoConnectEnabled)` together with its label (`sed -n 230,245p` to see the surrounding `HStack`/row). Leave the `@AppStorage` key in `AppSettings` (harmless; a later cleanup can drop it).

- [ ] **Step 5: Build and test**

Run the macOS build gate and the Mac test gate — Expected: `BUILD SUCCEEDED`; `MenuBarGroupingTests` passed; existing `MenuBarActivityTests`, `SessionNavigationTests` still pass.

- [ ] **Step 6: Commit**

```bash
git add CodeRelayMac/Views/ServerListWindow.swift CodeRelayMac/ViewModels/ServerListViewModel.swift CodeRelayMac/Views/MenuBarDropdown.swift \
  CodeRelayMac/ViewModels/MenuBarViewModel.swift CodeRelayMac/Views/SettingsView.swift CodeRelayMac/Views/MainWindow.swift \
  CodeRelayMacTests/MenuBarGroupingTests.swift
git commit -m "feat(mac): server management with per-bookmark Enabled, menu bar grouped by server

Connect is gone — servers are enabled or disabled; the status poller probes
only disabled bookmarks (D11); the auto-connect setting is retired.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Docs, gates, manual verification harness, PR

**Files:**
- Modify: `CLAUDE.md` ("App Architecture (iOS + macOS)" section), `Sources/CodeRelayClient/CLAUDE.md` (create if absent, else add a section)
- Create: `CodeRelayMac/Debug/HubPreviewSeed.swift` (`#if DEBUG` env-var harness)

- [ ] **Step 1: Documentation**

In `CLAUDE.md`, in "App Architecture (iOS + macOS)", after the first paragraph add:

```markdown
**Multi-server (macOS first; spec `docs/superpowers/specs/2026-10-28-multi-server-sessions-design.md`).**
`ServerHub<Slot>` (CodeRelayClient/Hub) owns one per-server coordinator per
**enabled** bookmark and the single global `activeRef: SessionRef` (bookmark
id + session id — never the server instance id). Coordinators are unchanged
except four additive hooks (`ownershipKeyPrefix`, `detachActive()`,
`serverIdentity`, `isAuthRejected`); the hub reaches them through
`ServerSlotCoordinating`, so hub tests run against a scripted fake. A
cross-server switch awaits a bounded `detachActive()` on the previous
coordinator before attaching (one attachment across all servers). An offline
server keeps its cached rows; selecting one triggers that server's recovery and
the selection is applied when a live list proves the session still exists.
Foreground/wake/network events fan out through the hub with a 150 ms stagger —
macOS coordinators no longer register their own wake observers. Deep links
(`SessionDeepLink`, scheme `coderelay`, optional `?server=<instanceId>`) route
instance id → unique session → single server's remote attach → not found.
`HubMigration` runs once: only the previously last-used bookmark stays enabled.
```

In `Sources/CodeRelayClient/CLAUDE.md` (create with a one-line header if it does not exist) add a "ServerHub" section listing the invariants above plus: "`ServerStatusChecker` polls only disabled bookmarks; the live connection is the status for enabled ones."

- [ ] **Step 2: Debug harness for screenshots**

Simulator taps are unavailable here (see memory `simulator-ui-automation-unavailable`); the macOS app can be launched directly. Create `CodeRelayMac/Debug/HubPreviewSeed.swift`:

```swift
#if DEBUG
import Foundation
import CodeRelayClient
import CodeRelayKit

/// `CODERELAY_HUB_SEED=1` makes the first `ServerHub` publish three canned
/// sections (live, offline-with-cache, token-rejected) so the sidebar, menu bar
/// and server window can be screenshot-verified without three relays.
enum HubPreviewSeed {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["CODERELAY_HUB_SEED"] == "1" }

    static func bookmarks() -> [ConnectionConfig] {
        [ConnectionConfig(name: "studio", host: "127.0.0.1", port: 9200, enabled: true),
         ConnectionConfig(name: "build-box", host: "10.0.0.9", port: 9200, enabled: true),
         ConnectionConfig(name: "laptop", host: "10.0.0.10", port: 9200, enabled: false)]
    }
}
#endif
```

and in `MacServerHubFactory.make` under `#if DEBUG`, when `HubPreviewSeed.isEnabled`, use an isolated `UserDefaults(suiteName: "hub-seed")` with those bookmarks saved and no tokens for the second bookmark (so it renders `authFailed`). Run the app with `CODERELAY_HUB_SEED=1` from Xcode's scheme environment or `open -a "Code[Relay]" --env CODERELAY_HUB_SEED=1` from the built product, screenshot the sidebar, the server window and the menu bar, and keep the screenshots out of git.

- [ ] **Step 3: Full gates**

Run: `swift build 2>&1 | tail -3; echo EXIT=${pipestatus[1]}` → `EXIT=0`.
Run: `swift test 2>&1 | tail -5; echo EXIT=${pipestatus[1]}` → `EXIT=0`, `All tests passed` (known: `SessionSwitchLatencyTests`/`SessionActivityMonitorTests` can flake on the CI runner, not locally).
Run the macOS build gate, the Mac test gate, and the iOS build gate → all succeed.
Run: `swiftlint lint --quiet 2>&1 | grep -E "Hub/|ServerSectionHeader|HubSidebar|ServerListWindow|MenuBar|SessionDeepLink|ConnectionConfig|SharedSessionCoordinator.swift|SessionController.swift" ; echo done` → no new warnings in touched files (compare against `main` with `git stash`-free method: `git show main:<file> > /tmp/x.swift && swiftlint lint --quiet /tmp/x.swift`).

- [ ] **Step 4: Commit and PR**

```bash
git add CLAUDE.md Sources/CodeRelayClient/CLAUDE.md CodeRelayMac/Debug/HubPreviewSeed.swift CodeRelayMac/ViewModels/MacServerHub.swift
git commit -m "docs(client,mac): ServerHub architecture notes and a debug seed for screenshot verification

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Branch `feat/multi-server-plan1-swift-hub-macos` from `main`; PR title `feat(mac): multi-server workspace — ServerHub + grouped sidebar (plan 1)`; body: summary of Tasks 1–10, the compatibility note (iOS unchanged apart from the scheme fix; one-server macOS users see one section and no other change), the test inventory, and the manual verification screenshots described in words. Wait for all four CI jobs; macOS flakes get `gh run rerun --failed`.

---

## Plan self-review notes

- **Spec coverage, Phase 1:** §5 (Tasks 2, 3), §7.1–7.7 (Tasks 4–6), §8.1 + §8.3 (Tasks 8–10), §9 (Tasks 2, 5, 7), §10 (Tasks 1, 6, 8), §11 (Task 10), §12 rows for offline/auth/restart/duplicate/hung detach/removed server/deep link (Tasks 4–6, 10), §13 (no token logging — Task 4's log line names the bookmark id only), §14 (stagger + per-slot keepalive untouched), §15.1 (hub tests with a fake, migration, codable, coordinator hooks), §15.3 macOS harness (Task 11). Native tabs bound to `SessionRef` (§8.3 last bullet) are **not** in this plan: the macOS app has no tab-per-session UI today, so there is nothing to rebind — ledger it as a ruling if a reviewer asks.
- **Terminal cache budget across the hub (§12 last row, §14):** not implemented in Plan 1 — each coordinator keeps its own LRU of 8. Deferred to a follow-up with a ledger ruling; eight servers × eight views is the worst case and only with eight enabled servers.
- **Type consistency checked:** `ServerSlotCoordinating` members vs `SharedSessionCoordinator` (Task 3 adds exactly `serverIdentity`, `isAuthRejected`, `connectionState`, `start`, `detachActive`); `ServerHub.select/createSession/removeServer/orderedRefs/selectNext/selectPrevious/handleDeepLink/handleForegroundTransition/syncPushRegistration/triggerUserRecovery/setEnabled/reloadBookmarks/slot(for:)/setCollapsed/isShowingServerList/notice` are the names Tasks 8–10 call; `HubStateStore` API matches Tasks 5 and 7; `ServerSectionHeaderModel` fields match Tasks 9 and 10.
- **Review Focus mapped:** 1 → Task 6 `testDuplicateInstanceIdIsFlagged` (+ Task 5 invariant), 2 → Task 4 `testMissingTokenBecomesAuthFailedSection`, 3 → Task 5 `testSelectingOfflineRowIsAppliedWhenServerReturns`, 4 → Task 5 `testRemoveActiveServerDetachesAndClearsActiveRef`, 5 → Task 7 `testMigrationWithMissingLastServer`.
