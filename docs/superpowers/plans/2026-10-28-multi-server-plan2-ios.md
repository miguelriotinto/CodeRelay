# Multi-Server Plan 2: iOS Client on `ServerHub` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The iOS app shows every enabled relay's sessions in one workspace — sidebar grouped by server, one attached session across servers, management screen with per-bookmark Enabled — on the `ServerHub` that shipped for macOS in v0.3.32. Plus one piece of visual feedback both apps share: whenever a session is on its way to the screen (switch, session-name refresh, reconnect) a bottom sheet names the step and the bytes loaded while the terminal fades to black, and both lift together the moment the session is ready.

**Architecture:** `CodeRelayApp` owns one `ServerHub<SessionCoordinator>` (`IOSServerHub`) built by `IOSServerHubFactory`; `WorkspaceView` becomes the root (the splash stays on top), `ServerListView` becomes the management sheet, `SessionSidebarView` renders one `ServerSectionHeader` per section over the unchanged workspace tiles, and `ActiveTerminalView` hosts the active coordinator's terminal with a session tab strip that spans servers. The iOS `SessionCoordinator` gains the same `init(config:token:ownershipKeyPrefix:)` / `start()` shape as the macOS one. Two shared-library changes: `SharedSessionCoordinator.connectionState` becomes `@Published` (mirrored from `connection.$state`) so the hub learns of socket changes on every platform, not only where a subclass mirrors them; and the three loading paths converge on one published signal (`sessionLoadPhase` is set at the START of every switch and every name-label reload, recovery keeps `isRecovering`/`recoveryPhase`) that a shared `SessionLoadingPresentation` turns into the sheet's text and a shared `SessionLoadingSheetModel` turns into "present / hold at least 600 ms / dismiss", which both the sheet and the terminal blackout follow.

**Tech Stack:** Swift 6.2, SwiftUI (iOS 17+), Combine, XCTest; XcodeGen (`project.yml`); SwiftTerm (unchanged).

**Spec:** `docs/superpowers/specs/2026-10-28-multi-server-sessions-design.md` — §8.1 (shared behaviour), §8.2 (iOS), §7 (hub), §9 (migration), §10 (deep links), §11 (management), §12 (edge cases), §15.3 (app tests). Plan 1 (`docs/superpowers/plans/2026-10-28-multi-server-plan1-swift-hub-macos.md`) built the hub and the macOS client; this plan consumes those interfaces unchanged except Task 1.

## Global Constraints

- **No version bumps in this plan.** `CodeRelayKit.version`, `project.yml` `CURRENT_PROJECT_VERSION`, the formula and PKGBUILDs stay as they are (the release skill owns them).
- **New Mac/iOS source files need `xcodegen generate`** and the regenerated `CodeRelay.xcodeproj/project.pbxproj` is committed with the task (ruling from Plan 1 Task 8).
- **iOS test module** is `@testable import CodeRelayApp`; Mac test module is `@testable import Code_Relay_`. iOS unit tests run on a simulator: `xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO`.
- **Gates for every task** (all must pass before `task-done`): `swift test` with `EXIT=0` read from `${pipestatus[1]}`; iOS build `xcodebuild build -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`; iOS tests (command above); Mac build-for-testing + test-without-building (`-scheme CodeRelayMac -destination 'platform=macOS'`) because Task 1 touches the shared coordinator.
- **Never** run the relay server binary directly, `pkill` the relay, or `claude-relay restart` (the user's live Claude sessions run inside it). Never log tokens. `git add` explicit paths only; no `git stash` / `checkout --` / `clean`.
- Commit trailer: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. PR bodies end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- **Hub semantics are fixed by Plan 1 and not re-opened here:** one `pendingRef == activeRef`; `selectionGeneration` on every selection path; `reconcileSelection` mirrors the coordinator; `focusCoordinator` drives single-server surfaces; cached rows kept while disabled but not selectable; `reloadBookmarks` enforces the cap of 8; `rebuildSlot` after a token edit; push unregister on disable/remove. The iOS views call these; they do not reimplement them.
- Per the memory `simulator-ui-automation-unavailable`: screenshots of the simulator work, taps do not. Visual verification uses the `CODERELAY_HUB_SEED=1` debug seed (Task 6) and `xcrun simctl openurl` for deep links.

## Review Focus

0. **The loading sheet must never stay up** (the one failure a user cannot tell from a hung app): every path that sets `sessionLoadPhase` or `isRecovering` must clear it on success AND on failure (RPC error, auth rejected, cancelled recovery, replay never delivered — `TerminalViewModel`'s 5 s reload backstop). Task 7's `testPresentationClearsOnEveryTerminalPath` plus `SharedSessionCoordinatorLoadPhaseTests.testReloadFromServerPublishesAttachingThenClearsOnFailure`.
1. **A push tap or `coderelay://` link arriving before `hub.start()` has finished (cold launch)** must attach the right session on the right server after the handshakes, not be dropped or attached on "the first server" as `ServerListView:126` did. Covered by `ServerHubRoutingTests.testDeepLinkBeforeStartIsQueued` (Plan 1) plus Task 3's `testDeepLinkBeforeHubIsRegisteredIsHeldUntilStart`.
2. **iPhone (compact): tapping a row on another server** must dismiss the sidebar sheet and show the *new* coordinator's terminal — the terminal host is keyed by coordinator identity (`.id(ObjectIdentifier(coordinator))`), otherwise SwiftTerm keeps hosting the old coordinator's view. Task 5's `testTerminalHostKeyChangesAcrossServers`.
3. **Zero bookmarks at launch** must present the management sheet over an explanatory empty state, never a black terminal; adding or pairing the first server builds a slot with no relaunch (`hub.reloadBookmarks()`). Task 3's `testEmptyStateOpensManagementAndFirstBookmarkStartsWithoutRelaunch`.
4. **Bookmarks restored from an iCloud backup to a new iPhone without their keychain tokens** (the Keychain items are device-scoped) must render every enabled section as `authFailed("No token stored…")` with a Re-pair action that opens the management screen, where editing the token rebuilds the slot — no crash, no silent blank. Covered by hub tests (`testMissingTokenBecomesAuthFailedSection`, `testRebuildSlotReplacesTheCoordinator`) plus Task 4's header test `testAuthFailedHeaderRetryOpensManagement`.
5. **Backgrounding with two servers enabled**: `scenePhase → .active` fans out through the hub once per server with the stagger; no coordinator installs its own observer, so nothing reconnects twice. Task 2's `testCoordinatorInstallsNoObserversOfItsOwn` and the hub's `testForegroundFanOutDoesNotSerializeBehindASlowServer`.
6. **A same-server switch to a session whose terminal is still cached** (SwiftTerm view alive, replay skipped) finishes in well under 100 ms: the sheet must still rise and settle cleanly rather than flicker, so the model holds it for a minimum of 600 ms and the blackout follows the same hold. Task 7's `testSheetHoldsAMinimumEvenWhenLoadingIsInstant` and `SharedSessionCoordinatorLoadPhaseTests.testSwitchPublishesAttachingEvenWithALiveTerminal`.

---

### Task 1: Shared — `connectionState` is published from the connection

**Files:**
- Modify: `Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift` (the `connectionState` computed property near line 1219; the init near line 317 where `activityObjectWillChangeSubscription` is set)
- Test: `Tests/CodeRelayClientTests/SharedSessionCoordinatorHubHooksTests.swift`

**Interfaces:**
- Consumes: `RelayConnection.$state` (`@Published public private(set) var state: ConnectionState`, `RelayConnection.swift:43`).
- Produces: `SharedSessionCoordinator.connectionState` as `@Published public private(set) var connectionState: RelayConnection.ConnectionState` — same name and type as before, so `ServerSlotCoordinating` and `ServerSectionStatus.derive` are untouched; the hub's `objectWillChange` subscription now fires on every socket transition on every platform (review minor M9 from Plan 1).

- [ ] **Step 1: Write the failing test**

Append inside `SharedSessionCoordinatorHubHooksTests`:

```swift
    func testConnectionStateIsPublishedAsTheSocketMoves() async {
        // The hub republishes on the coordinator's objectWillChange. A computed
        // `connectionState` never fired it, so on iOS (no subclass mirror) a
        // dropped socket left the section "live" until something else changed.
        let c = SharedSessionCoordinator(connection: RelayConnection(), token: "t", defaults: isolatedDefaults())
        var seen: [RelayConnection.ConnectionState] = []
        let sub = c.$connectionState.sink { seen.append($0) }
        defer { sub.cancel() }
        // Nothing listens on this port: the dial fails fast, so the state goes
        // .disconnected → .connecting → .disconnected without a server.
        try? await c.connection.connect(config: ConnectionConfig(name: "x", host: "127.0.0.1", port: 1), token: "t")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(seen.contains(.connecting), "saw \(seen)")
        XCTAssertEqual(seen.last, .disconnected)
        XCTAssertEqual(c.connectionState, .disconnected)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter SharedSessionCoordinatorHubHooksTests 2>&1 | tail -5; echo EXIT=${pipestatus[1]}`
Expected: compile error `value of type 'SharedSessionCoordinator' has no member '$connectionState'` (there is no published property yet).

- [ ] **Step 3: Implement**

In `SharedSessionCoordinator.swift`, replace the computed property

```swift
    public var connectionState: RelayConnection.ConnectionState { connection.state }
```

with a stored published one plus its mirror:

```swift
    /// Mirrors `connection.state` as a published value so the hub's
    /// `objectWillChange` subscription fires on every socket transition
    /// (`ServerSectionStatus.derive` reads it). Computed, it fired nothing: the
    /// macOS subclass happened to mirror the state into its own `isConnected`,
    /// iOS did not, and a dropped socket there stayed "live" in the sidebar.
    @Published public private(set) var connectionState: RelayConnection.ConnectionState = .disconnected
    private var connectionStateSubscription: AnyCancellable?
```

and in the designated initializer, right after `self.activityObjectWillChangeSubscription = …` (line ~317), add:

```swift
        connectionState = connection.state
        connectionStateSubscription = connection.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.connectionState = state }
```

(`import Combine` is already present in the file; check with `grep -n "^import Combine" Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift` and add it if not.)

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "SharedSessionCoordinatorHubHooksTests|ServerHubTests|ServerSectionHeaderTests" 2>&1 | grep -E "Executed|error:" | tail -4; echo EXIT=${pipestatus[1]}`
Expected: `EXIT=0`, the new test passes, hub tests unchanged.

Then the Mac gate (the Mac `StatusBarView` and `SessionCoordinator.isConnected` keep working — `isConnected` is still the Mac's own mirror):
Run: `xcodebuild build-for-testing -project CodeRelay.xcodeproj -scheme CodeRelayMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD" | tail -3` → `** TEST BUILD SUCCEEDED **`
Run: `xcodebuild test-without-building -project CodeRelay.xcodeproj -scheme CodeRelayMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests|failed" | tail -2` → 49 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift Tests/CodeRelayClientTests/SharedSessionCoordinatorHubHooksTests.swift
git commit -m "fix(client): publish connectionState from the socket so the hub sees every transition

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: iOS — `SessionCoordinator(config:token:ownershipKeyPrefix:)`, `start()`, `IOSServerHubFactory`

**Files:**
- Modify: `CodeRelayApp/ViewModels/SessionCoordinator.swift`
- Create: `CodeRelayApp/ViewModels/IOSServerHub.swift`
- Create: `CodeRelayAppTests/IOSServerHubTests.swift`

**Interfaces:**
- Consumes: `SharedSessionCoordinator.init(connection:token:ownershipKeyPrefix:defaults:)`, `open func start()`, `performHandshake(reason: .launch)`, `connection.connect(config:token:)`; `ServerHub.init(bookmarks:tokens:stateStore:keyPrefix:lastServerIdKey:defaults:factory:maxEnabled:stagger:sleep:)`; `HubStateStore(keyPrefix:deviceId:defaults:)`; `AuthManager.shared` (`TokenProviding` + `TokenDeleting`); `CodeRelayApp.savedConnections`; `DeviceIdentifier().currentID`.
- Produces: `typealias IOSServerHub = ServerHub<SessionCoordinator>`; `IOSServerHubFactory.make(defaults:) -> IOSServerHub`; `IOSServerHubFactory.makeCoordinator(config:token:) -> SessionCoordinator`; `IOSServerHubFactory.lastServerIdKey == "lastConnectedServerId"` (the `@AppStorage` key in `AppSettings`, which `HubMigration` reads and retires — spec §9).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import CodeRelayClient
@testable import CodeRelayApp

@MainActor
final class IOSServerHubTests: XCTestCase {
    func testFactoryNamespacesEachCoordinatorByBookmark() {
        let config = ConnectionConfig(name: "studio", host: "studio.local")
        let coordinator = IOSServerHubFactory.makeCoordinator(config: config, token: "t")
        XCTAssertEqual(coordinator.ownershipKeyPrefixForTest, "com.clauderelay.\(config.id.uuidString)")
        coordinator.tearDown()
    }

    func testMigrationReadsTheLegacyLastConnectedServerKey() {
        // AppSettings stores the pre-hub choice under this @AppStorage key; the
        // hub's one-time migration (spec §9) must read the same string.
        XCTAssertEqual(IOSServerHubFactory.lastServerIdKey, "lastConnectedServerId")
        let settings = AppSettings.shared
        let probe = UUID().uuidString
        let previous = settings.lastConnectedServerId
        settings.lastConnectedServerId = probe
        XCTAssertEqual(UserDefaults.standard.string(forKey: IOSServerHubFactory.lastServerIdKey), probe)
        settings.lastConnectedServerId = previous
    }

    func testCoordinatorInstallsNoObserversOfItsOwn() {
        // Wake/network events are fanned out by the hub with a stagger (D10);
        // a coordinator that also listened would reconnect twice per wake.
        let coordinator = SessionCoordinator(config: ConnectionConfig(name: "a", host: "127.0.0.1", port: 1),
                                             token: "t", ownershipKeyPrefix: "ios.test.\(UUID().uuidString)")
        XCTAssertFalse(coordinator.hasNetworkRecoveryForTest)
        coordinator.tearDown()
    }

    func testHubStartsWithTheSavedBookmarksInAnIsolatedSuite() async {
        let suite = "IOSServerHubTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let hub = IOSServerHubFactory.make(defaults: defaults)
        await hub.start()
        XCTAssertEqual(hub.aggregate.totalServers, CodeRelayApp.savedConnections.loadAll().count,
                       "the factory reads the app's bookmark store; the hub state lives in the given defaults")
        hub.stop()
    }
}
```

Add to `SharedSessionCoordinator` a test hook next to `ownershipKeyPrefixForTest` (Task 1's file, one line, no behaviour):

```swift
    /// Test hook: whether `startNetworkRecovery()` armed its monitor.
    public var hasNetworkRecoveryForTest: Bool { networkMonitor != nil }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && xcodebuild build-for-testing -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:" | head -5`
Expected: `cannot find 'IOSServerHubFactory' in scope`, `no exact matches in call to initializer` for `SessionCoordinator(config:…)`.

- [ ] **Step 3: Implement the coordinator subclass**

Replace `CodeRelayApp/ViewModels/SessionCoordinator.swift` with:

```swift
import Foundation
import CodeRelayClient
import CodeRelayKit

/// iOS-specific `SessionCoordinator`: one per enabled bookmark, built by
/// `IOSServerHubFactory`. It connects and runs the launch handshake in
/// `start()`; everything workspace-level (scenePhase, keyboard, network
/// restored) lives in `WorkspaceView` and is fanned out by the hub (D10), so
/// this class installs no observers of its own.
@MainActor
final class SessionCoordinator: SharedSessionCoordinator {

    private let config: ConnectionConfig

    // SwiftLint wants `static` on a final class, but the parent's declaration is
    // `open class var`, so the override MUST use `class`.
    // swiftlint:disable:next static_over_final_class
    override class var keyPrefix: String { "com.clauderelay" }

    override func sessionNamingTheme() -> SessionNamingTheme {
        AppSettings.shared.sessionNamingTheme
    }

    /// - Parameter ownershipKeyPrefix: per-server UserDefaults namespace from
    ///   the hub (multi-server D8); nil keeps the single-server default.
    init(config: ConnectionConfig, token: String, ownershipKeyPrefix: String? = nil) {
        self.config = config
        super.init(connection: RelayConnection(), token: token, ownershipKeyPrefix: ownershipKeyPrefix)
    }

    /// Dial, then the single-flight launch handshake (authenticate + list the
    /// sessions this client owns). A failed first dial falls through: the
    /// handshake reconnects on its own, so it becomes a retry rather than a
    /// dead section. Mirrors the macOS subclass exactly.
    override func start() async {
        do {
            try await connection.connect(config: config, token: token)
        } catch {
            presentError(error.localizedDescription)
        }
        await performHandshake(reason: .launch)
    }
}
```

Check `token` and `presentError` are accessible from a subclass (`grep -n "let token\|var token\|func presentError" Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift`); the Mac subclass uses both, so they are at least `open`/`public`.

- [ ] **Step 4: Implement the factory**

Create `CodeRelayApp/ViewModels/IOSServerHub.swift`:

```swift
import Foundation
import CodeRelayClient

typealias IOSServerHub = ServerHub<SessionCoordinator>

/// Builds the one hub the app owns (multi-server spec §7, §8.2).
@MainActor
enum IOSServerHubFactory {
    /// The single-server build's `@AppStorage("lastConnectedServerId")`; the
    /// hub's one-time migration reads and retires it (spec §9).
    static let lastServerIdKey = "lastConnectedServerId"

    /// One coordinator per bookmark, each with its own ownership namespace so
    /// two relays never share a session-name map (D8).
    static func makeCoordinator(config: ConnectionConfig, token: String) -> SessionCoordinator {
        SessionCoordinator(config: config, token: token,
                           ownershipKeyPrefix: "\(SessionCoordinator.keyPrefix).\(config.id.uuidString)")
    }

    static func make(defaults: UserDefaults = .standard) -> IOSServerHub {
        #if DEBUG
        if HubPreviewSeed.isEnabled {
            let seed = HubPreviewSeed.makeStores(keyPrefix: SessionCoordinator.keyPrefix,
                                                 deviceId: DeviceIdentifier().currentID)
            return ServerHub(
                bookmarks: seed.bookmarks,
                tokens: seed.tokens,
                stateStore: seed.state,
                keyPrefix: SessionCoordinator.keyPrefix,
                lastServerIdKey: lastServerIdKey,
                defaults: seed.defaults,
                factory: { config, token in makeCoordinator(config: config, token: token) })
        }
        #endif
        return ServerHub(
            bookmarks: CodeRelayApp.savedConnections,
            tokens: AuthManager.shared,
            stateStore: HubStateStore(keyPrefix: SessionCoordinator.keyPrefix,
                                      deviceId: DeviceIdentifier().currentID, defaults: defaults),
            keyPrefix: SessionCoordinator.keyPrefix,
            lastServerIdKey: lastServerIdKey,
            defaults: defaults,
            factory: { config, token in makeCoordinator(config: config, token: token) })
    }
}
```

The `#if DEBUG` block references `HubPreviewSeed`, which Task 6 creates. **For this task, create a minimal `CodeRelayApp/Debug/HubPreviewSeed.swift` now** (Task 6 fills it in):

```swift
#if DEBUG
import Foundation
import CodeRelayClient

/// `CODERELAY_HUB_SEED=1` seeds canned bookmarks in an isolated defaults
/// suite for screenshot verification (filled in by Plan 2 Task 6).
@MainActor
enum HubPreviewSeed {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["CODERELAY_HUB_SEED"] == "1" }
    static let suiteName = "hub-seed"

    final class Tokens: TokenProviding {
        let tokenId: UUID
        let borrowed: String?
        init(tokenId: UUID, borrowed: String?) { self.tokenId = tokenId; self.borrowed = borrowed }
        func loadToken(for connectionId: UUID) throws -> String? { connectionId == tokenId ? borrowed : nil }
    }

    static func bookmarks() -> [ConnectionConfig] {
        [ConnectionConfig(name: "studio", host: "127.0.0.1", port: 9200, enabled: true),
         ConnectionConfig(name: "build-box", host: "10.0.0.9", port: 9200, enabled: true),
         ConnectionConfig(name: "laptop", host: "10.0.0.10", port: 9200, enabled: false)]
    }

    static func makeStores(keyPrefix: String, deviceId: String)
        -> (defaults: UserDefaults, bookmarks: SavedConnectionStore, tokens: Tokens, state: HubStateStore) {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let list = bookmarks()
        let store = SavedConnectionStore(key: "hub-seed.savedConnections", defaults: defaults)
        store.saveAll(list)
        let state = HubStateStore(keyPrefix: keyPrefix, deviceId: deviceId, defaults: defaults)
        state.markMigrated()
        return (defaults, store, Tokens(tokenId: list[0].id, borrowed: nil), state)
    }
}
#endif
```

- [ ] **Step 5: Run the tests**

Run: `xcodegen generate && xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CodeRelayAppTests/IOSServerHubTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed|error:|failed" | tail -4`
Expected: 4 tests, 0 failures. (The iOS target still compiles because nothing else constructs `SessionCoordinator` with the old initializer — `WorkspaceView.init` does; **if the build fails there**, Task 3 replaces that view: temporarily change its initializer call to `SessionCoordinator(config: ConnectionConfig(name: "", host: ""), token: token)` is NOT acceptable — instead do Task 2 and Task 3's Step 3 in the same build cycle and record the ruling, as Plan 1 did for Tasks 8/9.)

- [ ] **Step 6: Commit**

```bash
git add CodeRelayApp/ViewModels/SessionCoordinator.swift CodeRelayApp/ViewModels/IOSServerHub.swift CodeRelayApp/Debug/HubPreviewSeed.swift CodeRelayAppTests/IOSServerHubTests.swift Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift CodeRelay.xcodeproj/project.pbxproj
git commit -m "feat(ios): SessionCoordinator per bookmark and the IOSServerHub factory

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: iOS — the hub owns the workspace; `ServerListView` becomes the management sheet

**Files:**
- Modify: `CodeRelayApp/CodeRelayApp.swift`, `CodeRelayApp/Views/WorkspaceView.swift`, `CodeRelayApp/Views/ServerListView.swift`, `CodeRelayApp/ViewModels/ServerListViewModel.swift`, `CodeRelayApp/Views/SettingsView.swift` (remove the "Auto Connect" section), `CodeRelayApp/Views/PairWithHostSheet.swift` (no change needed — `onPaired` already returns the saved config)
- Create: `CodeRelayAppTests/WorkspaceRootTests.swift`

**Interfaces:**
- Consumes: `IOSServerHub` (Task 2); hub API: `start()`, `stop()`, `reloadBookmarks()`, `rebuildSlot(_:)`, `setEnabled(_:_:)`, `removeServer(_:)`, `handleDeepLink(_:) -> DeepLinkOutcome`, `handleForegroundTransition(userInitiated:)`, `syncPushRegistration(pushEnabled:notifyOnFinished:)`, `focusCoordinator`, `activeCoordinator`, `activeRef`, `sections`, `aggregate`, `notice`, `isShowingServerList`; shared `ServerSectionHeaderModel(section:)` for the management rows; `ServerStatusChecker` (disabled bookmarks only); `NetworkMonitor.connectivityRestored`.
- Produces: `WorkspaceView(hub:)` as the root view; `ServerListView(hub:)` management sheet with Enabled toggles; `ServerListViewModel.pollTargets(_:)`; `WorkspaceRoot.shouldPresentManagement(aggregate:)` (pure) used by the empty state; `RecoveryOverlay(phase:serverName:onCancel:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import CodeRelayClient
@testable import CodeRelayApp

@MainActor
final class WorkspaceRootTests: XCTestCase {
    func testStatusCheckerTargetsOnlyDisabledBookmarks() {
        let a = ConnectionConfig(name: "a", host: "a", enabled: true), b = ConnectionConfig(name: "b", host: "b", enabled: false)
        XCTAssertEqual(ServerListViewModel.pollTargets([a, b]).map(\.id), [b.id])
    }

    func testEmptyStateOpensManagementAndFirstBookmarkStartsWithoutRelaunch() {
        var agg = HubAggregate()
        XCTAssertTrue(WorkspaceRoot.shouldPresentManagement(aggregate: agg), "zero bookmarks: the sheet is the only way forward")
        agg.totalServers = 1; agg.enabledServers = 0
        XCTAssertTrue(WorkspaceRoot.shouldPresentManagement(aggregate: agg), "bookmarks exist but none enabled")
        agg.enabledServers = 1
        XCTAssertFalse(WorkspaceRoot.shouldPresentManagement(aggregate: agg), "an enabled server: the workspace shows it")
    }

    func testDeepLinkBeforeHubIsRegisteredIsHeldUntilStart() async {
        // The App struct receives onOpenURL before WorkspaceView's .task has
        // called hub.start(); the hub queues it (startGate) — so the root must
        // hand the link straight to the hub, never drop it when no slot exists.
        let suite = "WorkspaceRootTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let hub = IOSServerHubFactory.make(defaults: defaults)
        let router = DeepLinkRouter(hub: hub)
        let pending = Task { await router.open(URL(string: "coderelay://session/\(UUID().uuidString)")!) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(pending.isCancelled)
        await hub.start()
        let outcome = await pending.value
        XCTAssertNotNil(outcome, "routed after start, not dropped")
        hub.stop()
    }

    func testPairingURLsStillGoToThePairingSheet() async {
        let suite = "WorkspaceRootTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let hub = IOSServerHubFactory.make(defaults: defaults)
        let router = DeepLinkRouter(hub: hub)
        let outcome = await router.open(URL(string: "coderelay://pair?host=h&port=9200&tls=0&code=ABCDEFGH")!)
        if case .pairing = outcome {} else { XCTFail("expected .pairing, got \(String(describing: outcome))") }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild build-for-testing -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:" | head -6`
Expected: `cannot find 'WorkspaceRoot' in scope`, `cannot find 'DeepLinkRouter' in scope`, `type 'ServerListViewModel' has no member 'pollTargets'`.

- [ ] **Step 3: Rewrite `CodeRelayApp.swift`**

Replace the `CodeRelayApp` struct and add `DeepLinkRouter` (keep `PushAppDelegate` and the `PairingURL: Identifiable` extension as they are):

```swift
/// Routes an incoming URL: pairing links open the pairing sheet; session links
/// go to the hub, which queues them until `start()` has finished (spec §10).
@MainActor
struct DeepLinkRouter {
    enum Outcome: Equatable {
        case pairing(PairingURL)
        case session(IOSServerHub.DeepLinkOutcome)
        case ignored
    }

    let hub: IOSServerHub

    func open(_ url: URL) async -> Outcome {
        if url.host == "pair", let pairing = PairingURL(url: url) { return .pairing(pairing) }
        guard let link = SessionDeepLink(url: url) else { return .ignored }
        return .session(await hub.handleDeepLink(link))
    }
}

extension PairingURL: @retroactive Equatable {
    public static func == (lhs: PairingURL, rhs: PairingURL) -> Bool { lhs.urlString == rhs.urlString }
}

@main
struct CodeRelayApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate

    /// Platform-scoped server bookmark storage. The legacy key migrates
    /// existing users from the old `com.coderemote.*` prefix transparently.
    static let savedConnections = SavedConnectionStore(
        key: "com.clauderelay.ios.savedConnections",
        legacyKeys: ["com.coderemote.savedConnections"]
    )

    /// The one hub (multi-server spec §8.2): owned here, not by a view that can
    /// be recreated, so a deep link that arrives during launch has a target.
    @StateObject private var hub = IOSServerHubFactory.make()
    @State private var showSplash = true
    @State private var pendingPairing: PairingURL?

    var body: some Scene {
        WindowGroup {
            ZStack {
                WorkspaceView(hub: hub)

                if showSplash {
                    SplashScreenView {
                        showSplash = false
                    }
                    .transition(.identity)
                }
            }
            .onOpenURL { url in
                Task { await route(url) }
            }
            .onReceive(PushTokenBridge.shared.$pendingDeepLink.compactMap { $0 }) { url in
                Task { await route(url) }
                PushTokenBridge.shared.pendingDeepLink = nil
            }
            .task {
                // Request notification permission once the UI is up, if the
                // user hasn't disabled push in settings.
                if AppSettings.shared.pushNotificationsEnabled {
                    pushDelegate.requestAndRegister()
                }
            }
            .sheet(item: $pendingPairing) { pairing in
                PairWithHostSheet(onPaired: { _ in
                    // The paired bookmark is saved enabled; reloading builds its
                    // coordinator (the cap is enforced by the hub).
                    hub.reloadBookmarks()
                }, prefill: pairing)
            }
        }
    }

    private func route(_ url: URL) async {
        switch await DeepLinkRouter(hub: hub).open(url) {
        case .pairing(let pairing): pendingPairing = pairing
        case .session, .ignored: break    // the hub published a notice for .notFound
        }
    }
}
```

- [ ] **Step 4: Rewrite `WorkspaceView.swift`**

```swift
import SwiftUI
import CodeRelayClient
import CodeRelayKit

// MARK: - Recovery Overlay (shown while the ACTIVE server reconnects)

struct RecoveryOverlay: View {
    let phase: SharedSessionCoordinator.RecoveryPhase
    /// Spec §8.1: the sheet names the server, since other servers keep working.
    let serverName: String?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView().scaleEffect(1.5)
            Text(serverName.map { "Reconnecting to \($0)" } ?? "Reconnecting")
                .font(.headline)
            Text(phase.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: phase.label)
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Centre on the sheet's full width, not its safe area (iPhone Duo's
        // status-bar column is carved out of a sheet's safe area; see git
        // history of this view for the full reasoning).
        .ignoresSafeArea(.container, edges: .horizontal)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// Pure rules the root view is built on, kept out of SwiftUI for tests.
enum WorkspaceRoot {
    /// With no enabled server there is nothing to show behind the terminal:
    /// present the management sheet (spec §8.1 "root screen is the workspace;
    /// with zero bookmarks it shows the existing add/pair empty state").
    static func shouldPresentManagement(aggregate: HubAggregate) -> Bool {
        aggregate.enabledServers == 0
    }
}

/// Main workspace over the hub: NavigationSplitView with a grouped session
/// sidebar and the active coordinator's terminal (spec §8.2).
struct WorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject var hub: IOSServerHub
    @ObservedObject private var settings = AppSettings.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showSidebarSheet = false
    @State private var networkMonitor = NetworkMonitor()

    /// Maps the sidebar button's columnVisibility toggle directly to showSidebarSheet on iPhone.
    private var sidebarSheetBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { showSidebarSheet ? .all : .detailOnly },
            set: { newValue in showSidebarSheet = (newValue == .all) }
        )
    }

    /// Reconcile every enabled relay's push registration with settings/token.
    private func syncPush() async {
        await hub.syncPushRegistration(
            pushEnabled: settings.pushNotificationsEnabled,
            notifyOnFinished: settings.pushNotifyOnFinished)
    }

    var body: some View {
        Group {
            if sizeClass == .compact {
                // iPhone: detail-only with the sidebar as a sheet
                ActiveTerminalView(hub: hub, columnVisibility: sidebarSheetBinding)
                    .sheet(isPresented: $showSidebarSheet) {
                        NavigationStack {
                            SessionSidebarView(hub: hub)
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button("Done") { showSidebarSheet = false }
                                    }
                                }
                        }
                        .presentationDetents([.medium, .large])
                    }
            } else {
                // iPad: full split view
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SessionSidebarView(hub: hub)
                } detail: {
                    ActiveTerminalView(hub: hub, columnVisibility: $columnVisibility)
                }
                .navigationSplitViewStyle(.prominentDetail)
                .navigationBarHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .task {
            await hub.start()
            await syncPush()
            if WorkspaceRoot.shouldPresentManagement(aggregate: hub.aggregate) {
                hub.isShowingServerList = true
            } else if hub.activeRef == nil {
                if sizeClass == .compact { showSidebarSheet = true } else { columnVisibility = .all }
            }
        }
        // Re-sync push registration when the OS vends/rotates a token or the
        // user changes push settings.
        .onReceive(PushTokenBridge.shared.$deviceToken) { _ in Task { await syncPush() } }
        .onChange(of: settings.pushNotificationsEnabled) { _, _ in Task { await syncPush() } }
        .onChange(of: settings.pushNotifyOnFinished) { _, _ in Task { await syncPush() } }
        .onChange(of: hub.activeRef) { _, newValue in
            if newValue != nil {
                withAnimation {
                    columnVisibility = .detailOnly
                    showSidebarSheet = false
                }
            }
        }
        .onDisappear { hub.stop() }
        // Foreground and network-restored fan out through the hub with a
        // stagger (D10); coordinators install no observers of their own.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { Task { await hub.handleForegroundTransition(userInitiated: true) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NetworkMonitor.connectivityRestored)) { _ in
            Task { await hub.handleForegroundTransition(userInitiated: true) }
        }
        // The sheets and alerts that belong to one coordinator live on a child
        // view that exists only while the focus coordinator does (the active
        // server, else the only / first live one — G8).
        .background {
            if let focus = hub.focusCoordinator {
                FocusCoordinatorModifiers(coordinator: focus,
                                          serverName: hub.sections.first { $0.id == hub.focusServerId }?.title)
                    .id(ObjectIdentifier(focus))
            }
        }
        .sheet(isPresented: $hub.isShowingServerList) {
            ServerListView(hub: hub)
        }
        .overlay(alignment: .top) {
            if let notice = hub.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(4))
                        if hub.notice == notice { hub.notice = nil }
                    }
            }
        }
    }
}

/// Sheets and alerts bound to one coordinator's published flags, rendered as an
/// invisible background child so each binding is non-optional.
private struct FocusCoordinatorModifiers: View {
    @ObservedObject var coordinator: SessionCoordinator
    let serverName: String?

    var body: some View {
        Color.clear
            .sheet(isPresented: $coordinator.isRecovering) {
                RecoveryOverlay(phase: coordinator.recoveryPhase, serverName: serverName,
                                onCancel: { coordinator.cancelRecovery() })
                    .interactiveDismissDisabled()
            }
            .alert("Connection Lost", isPresented: $coordinator.connectionTimedOut) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Unable to reconnect to \(serverName ?? "the server"). Check your network, then pull to refresh.")
            }
            .alert("Error", isPresented: $coordinator.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(coordinator.errorMessage ?? "Unknown error")
            }
            .alert("Cannot Open Session", isPresented: $coordinator.sessionAttachFailed) {
                Button("OK", role: .cancel) { coordinator.sessionAttachError = nil }
            } message: {
                Text(coordinator.sessionAttachError ?? "Unable to attach to this session.")
            }
            .alert(
                "Session Moved",
                isPresented: Binding(
                    get: { coordinator.activityCoordinator.showSessionStolen },
                    set: { coordinator.activityCoordinator.showSessionStolen = $0 }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                if let name = coordinator.activityCoordinator.stolenSessionName,
                   let shortId = coordinator.activityCoordinator.stolenSessionShortId {
                    Text("\(name) (\(shortId)) was attached from another device.")
                }
            }
    }
}
```

Note `@State private var networkMonitor = NetworkMonitor()` keeps one monitor alive for the view's lifetime so `connectivityRestored` posts (the coordinator's own `startNetworkRecovery()` is no longer called — see Task 2). Check `NetworkMonitor.init` is public and starts monitoring on init (`sed -n 1,40p Sources/CodeRelayClient/Helpers/NetworkMonitor.swift`); if it needs a `start()` call, add `.onAppear { networkMonitor.start() }` — read the file, do not guess.

- [ ] **Step 5: Rewrite `ServerListViewModel.swift` and `ServerListView.swift`**

`ServerListViewModel.swift`:

```swift
import Foundation
import SwiftUI
import Combine
import CodeRelayClient

/// The server management list (spec §8.1, §11). Enabled bookmarks are live in
/// the hub — their status comes from there. Only disabled bookmarks are probed
/// by the status poller (D11), so no bookmark is ever probed twice.
@MainActor
final class ServerListViewModel: ObservableObject {
    @Published private(set) var servers: [ConnectionConfig] = []
    @Published private(set) var serverStatuses: [UUID: ServerStatus] = [:]

    private let statusChecker = ServerStatusChecker(interval: 15)

    init() {
        statusChecker.$statuses.assign(to: &$serverStatuses)
        refreshServers()
    }

    deinit {
        let checker = statusChecker
        Task { @MainActor in checker.stopPolling() }
    }

    static func pollTargets(_ connections: [ConnectionConfig]) -> [ConnectionConfig] {
        connections.filter { !$0.enabled }
    }

    func refreshServers() {
        servers = CodeRelayApp.savedConnections.loadAll()
        statusChecker.refresh(connections: Self.pollTargets(servers))
    }

    func stopPolling() { statusChecker.stopPolling() }
}
```

Check `ServerStatusChecker.init(interval:)` exists (`grep -n "public init" Sources/CodeRelayClient/ViewModels/ServerStatusChecker.swift`); the Mac view model uses it.

`ServerListView.swift` (replaces the whole file; `ConnectingView` is deleted — nothing else uses it: `grep -rn ConnectingView CodeRelayApp` must return only this file):

```swift
import SwiftUI
import CodeRelayClient
import CodeRelayKit

/// Server management (multi-server spec §8.1, §11): every bookmark with an
/// **Enabled** toggle. There is no Connect — enabled servers are live in the
/// workspace, disabled ones are only probed by the status poller.
struct ServerListView: View {
    @ObservedObject var hub: IOSServerHub
    @StateObject private var viewModel = ServerListViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showAddSheet = false
    @State private var showSettings = false
    @State private var serverToEdit: ConnectionConfig?
    @State private var showScanner = false
    @State private var showManualPair = false
    @State private var scannedPairing: PairingURL?

    var body: some View {
        NavigationStack {
            contentView
                .navigationTitle("Servers")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { showSettings = true } label: { Image(systemName: "gear") }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showAddSheet = true } label: { Image(systemName: "plus") }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { showScanner = true } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
                            Button { showManualPair = true } label: { Label("Enter Code Manually", systemImage: "keyboard") }
                        } label: {
                            Image(systemName: "link.badge.plus")
                        }
                    }
                    if hub.aggregate.enabledServers > 0 {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
                .sheet(isPresented: $showSettings) { SettingsView(settings: AppSettings.shared) }
                .sheet(isPresented: $showAddSheet) {
                    AddEditServerView(mode: .add) { _ in
                        viewModel.refreshServers()
                        hub.reloadBookmarks()
                    }
                }
                .sheet(item: $serverToEdit) { server in
                    AddEditServerView(mode: .edit(server), onSave: { saved in
                        viewModel.refreshServers()
                        hub.reloadBookmarks()
                        // The hub cannot see the keychain: a pasted token only
                        // reaches the relay through a fresh coordinator.
                        hub.rebuildSlot(saved.id)
                    }, onDelete: {
                        Task { await hub.removeServer(server.id); viewModel.refreshServers() }
                    })
                }
                .sheet(isPresented: $showScanner) {
                    NavigationStack {
                        QRScannerView { value in
                            showScanner = false
                            if let pairing = PairingURL(string: value) { scannedPairing = pairing }
                        }
                        .navigationTitle("Scan QR Code")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScanner = false } }
                        }
                    }
                }
                .sheet(item: $scannedPairing) { pairing in
                    PairWithHostSheet(onPaired: { _ in paired() }, prefill: pairing)
                }
                .sheet(isPresented: $showManualPair) {
                    PairWithHostSheet(onPaired: { _ in paired() }, prefill: nil)
                }
                .onAppear { viewModel.refreshServers() }
                .onDisappear { viewModel.stopPolling() }
        }
        .interactiveDismissDisabled(hub.aggregate.enabledServers == 0)
    }

    private func paired() {
        viewModel.refreshServers()
        hub.reloadBookmarks()          // paired bookmarks are saved enabled; the cap is enforced there
    }

    @ViewBuilder
    private var contentView: some View {
        if hub.sections.isEmpty {
            ContentUnavailableView {
                Label("No Servers", systemImage: "server.rack")
            } description: {
                Text("Add or pair a server to get started.")
            } actions: {
                Button("Add Server") { showAddSheet = true }
                Button("Pair with QR Code") { showScanner = true }
            }
        } else {
            List {
                if let notice = hub.notice {
                    Section { Text(notice).font(.footnote).foregroundStyle(.orange) }
                }
                ForEach(hub.sections) { section in
                    ServerRowView(
                        section: section,
                        probe: viewModel.serverStatuses[section.id],
                        onToggle: { on in
                            _ = hub.setEnabled(section.id, on)   // a refusal (cap of 8) leaves hub.notice
                            viewModel.refreshServers()
                        }
                    )
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await hub.removeServer(section.id); viewModel.refreshServers() }
                        } label: { Label("Delete", systemImage: "trash") }
                        Button { serverToEdit = section.config } label: { Label("Edit", systemImage: "pencil") }
                            .tint(.blue)
                    }
                }
                Section {
                    Text("\(hub.aggregate.enabledServers) of \(hub.aggregate.totalServers) enabled · up to 8 at once")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Server Row

struct ServerRowView: View {
    let section: ServerSection
    let probe: ServerStatus?
    let onToggle: (Bool) -> Void

    private var model: ServerSectionHeaderModel { ServerSectionHeaderModel(section: section) }

    /// Enabled bookmarks show the live coordinator's status; disabled ones the
    /// poller's probe (reachable / token rejected / offline).
    private var dotColor: Color {
        if section.config.enabled { return model.dotColor }
        guard let probe else { return .gray }
        if probe.reachability == .invalidToken { return .orange }
        return probe.isLive ? .green : .red
    }

    private var statusLabel: String {
        if section.config.enabled { return model.subtitle ?? "connected" }
        guard let probe else { return "disabled" }
        if probe.reachability == .invalidToken { return "disabled · token rejected" }
        return probe.isLive ? "disabled · reachable" : "disabled · offline"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(section.title).font(.body).fontWeight(.medium)
                    if section.isDuplicateInstance {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            .accessibilityLabel("Another bookmark points at this same relay")
                    }
                }
                Text(verbatim: "\(section.config.useTLS ? "wss" : "ws")://\(section.config.host):\(section.config.port)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                    Text(statusLabel).font(.caption2).foregroundStyle(.secondary)
                }
                if let instance = section.config.instanceId {
                    Text("instance \(instance.uuidString.prefix(8))…").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { section.config.enabled }, set: onToggle))
                .labelsHidden()
        }
    }
}
```

Check `AddEditServerView(mode:onSave:onDelete:)`'s `onSave` closure passes the saved `ConnectionConfig` (`grep -n "onSave" CodeRelayApp/Views/AddEditServerView.swift`); the old call sites ignored it with `_ in`, so it exists.

- [ ] **Step 6: Settings — drop the Auto Connect section**

In `CodeRelayApp/Views/SettingsView.swift` delete the first `Section { Toggle("Auto Connect", …) } header: { Text("Connection") } footer: { … }` block (lines ~15–21). Keep `AppSettings.autoConnectEnabled` and `lastConnectedServerId` properties: the migration reads the latter once and `removeObject`s it; the former is simply unused now (deleting the `@AppStorage` would not remove the stored value anyway).

- [ ] **Step 7: Build and run the tests**

Run: `xcodegen generate && xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CodeRelayAppTests/WorkspaceRootTests -only-testing:CodeRelayAppTests/IOSServerHubTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed|error:|failed" | tail -5`
Expected: the build fails on `ActiveTerminalView(hub:)` and `SessionSidebarView(hub:)` not existing yet. **Ruling to record** (as Plan 1 Task 8 did): Tasks 3, 4 and 5 compile together; write Task 4's and Task 5's RED tests and implementations in the same build cycle, then run all three tasks' tests, and commit as three commits (`git add` the files per task). The ledger notes this once.

- [ ] **Step 8: Commit (after Tasks 4 and 5 compile)**

```bash
git add CodeRelayApp/CodeRelayApp.swift CodeRelayApp/Views/WorkspaceView.swift CodeRelayApp/Views/ServerListView.swift CodeRelayApp/ViewModels/ServerListViewModel.swift CodeRelayApp/Views/SettingsView.swift CodeRelayAppTests/WorkspaceRootTests.swift CodeRelay.xcodeproj/project.pbxproj
git commit -m "feat(ios): the ServerHub owns the workspace; server list becomes the management sheet

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: iOS — sidebar grouped by server

**Files:**
- Modify: `CodeRelayApp/Views/SessionSidebarView.swift`
- Create: `CodeRelayAppTests/SidebarSectionsTests.swift`

**Interfaces:**
- Consumes: `hub.sections`, `hub.activeRef`, `hub.select(_:)`, `hub.createSession(on:)`, `hub.triggerUserRecovery(serverId:)`, `hub.setCollapsed(_:_:)`, `hub.slot(for:)`, `hub.focusCoordinator`, `hub.handleForegroundTransition(userInitiated:)`, `hub.isShowingServerList`; shared `ServerSectionHeader(model:isCollapsed:onToggle:onRetry:onNew:)` and `ServerSectionHeaderModel(section:)` (CodeRelayClient/Views); `WorkspaceTileHeader`, `.workspaceTileRow`, `SidebarCollapseModel`, `coordinator.activityCoordinator.rollups(for:)`, `coordinator.loadCollapsedGroups()/saveCollapsedGroups`.
- Produces: `SessionSidebarView(hub:)`; pure `SessionSidebarView.rows(for:) -> [Row]` (flattened, collapsed sections skipped, `isCached` per row); `SessionSidebarView.retryAction(for:) -> RetryAction` (`.openManagement` for `authFailed`, `.recover` otherwise).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import CodeRelayClient
import CodeRelayKit
@testable import CodeRelayApp

final class SidebarSectionsTests: XCTestCase {
    private func section(_ name: String, _ status: ServerSectionStatus, sessions: Int, collapsed: Bool = false) -> ServerSection {
        let c = ConnectionConfig(name: name, host: name)
        let list = (0..<sessions).map { _ in
            SessionInfo(id: UUID(), state: .activeDetached, tokenId: "t", createdAt: Date(), cols: 80, rows: 24)
        }
        return ServerSection(config: c, status: status, sessions: list, isCached: !status.isLive,
                             rollups: [], awaitingInput: 0, isCollapsed: collapsed)
    }

    func testRowsFollowSidebarOrderSkipCollapsedAndMarkCached() {
        let a = section("a", .live, sessions: 2), b = section("b", .offline, sessions: 1), c = section("c", .live, sessions: 1, collapsed: true)
        let rows = SessionSidebarView.rows(for: [a, b, c])
        XCTAssertEqual(rows.map(\.ref.serverId), [a.id, a.id, b.id], "c is collapsed; order is sidebar order")
        XCTAssertEqual(rows.map(\.isCached), [false, false, true], "offline rows are cached (D4)")
    }

    func testAuthFailedHeaderRetryOpensManagement() {
        XCTAssertEqual(SessionSidebarView.retryAction(for: section("a", .authFailed("Token rejected"), sessions: 0)), .openManagement,
                       "re-pairing happens on the management screen, not by retrying the rejected token")
        XCTAssertEqual(SessionSidebarView.retryAction(for: section("a", .offline, sessions: 0)), .recover)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Expected on build: `type 'SessionSidebarView' has no member 'rows'`, `no member 'retryAction'`.

- [ ] **Step 3: Rewrite `SessionSidebarView.swift`**

Replace the `SessionSidebarView` struct (keep `SessionRow`, `AttachSessionSheet`, `QRScannerSheet` below it, with the two changes noted after the code):

```swift
/// Sidebar content for the workspace: one collapsible section per server
/// (spec §8.1/§8.2), each holding the unchanged workspace tiles and session
/// rows of that server. Tapping a row calls `hub.select(ref)`.
struct SessionSidebarView: View {
    @ObservedObject var hub: IOSServerHub
    @State private var showAttachSheet = false
    @State private var attachableSessions: [SessionInfo] = []
    @State private var isLoadingAttachable = false
    @State private var showQRSheet = false
    @State private var qrRef: SessionRef?

    struct Row: Equatable {
        let ref: SessionRef
        let session: SessionInfo
        let isCached: Bool
    }

    enum RetryAction: Equatable { case recover, openManagement }

    /// Flattened rows in sidebar order, skipping collapsed sections. Pure, for
    /// tests and for parity with `ServerHub.orderedRefs`.
    static func rows(for sections: [ServerSection]) -> [Row] {
        sections.flatMap { section -> [Row] in
            guard !section.isCollapsed else { return [] }
            return section.sessions.map {
                Row(ref: SessionRef(serverId: section.id, sessionId: $0.id), session: $0, isCached: section.isCached)
            }
        }
    }

    /// A rejected token is fixed on the management screen (Re-pair); anything
    /// else is a recovery of that one server.
    static func retryAction(for section: ServerSection) -> RetryAction {
        if case .authFailed = section.status { return .openManagement }
        return .recover
    }

    var body: some View {
        List {
            Section {
                if let focus = hub.focusCoordinator {
                    Button {
                        isLoadingAttachable = true
                        Task {
                            attachableSessions = await focus.fetchAttachableSessions()
                            isLoadingAttachable = false
                            showAttachSheet = true
                        }
                    } label: {
                        Label("Attach Session", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(isLoadingAttachable)
                }
                Button {
                    hub.isShowingServerList = true
                } label: {
                    Label("Servers", systemImage: "server.rack")
                }
            }
            .listSectionSpacing(20)

            ForEach(hub.sections) { section in
                Section {
                    ServerSectionHeader(
                        model: ServerSectionHeaderModel(section: section),
                        isCollapsed: section.isCollapsed,
                        onToggle: { hub.setCollapsed(section.id, !section.isCollapsed) },
                        onRetry: {
                            switch Self.retryAction(for: section) {
                            case .openManagement: hub.isShowingServerList = true
                            case .recover: hub.triggerUserRecovery(serverId: section.id)
                            }
                        },
                        onNew: section.status.isLive ? { Task { await hub.createSession(on: section.id) } } : nil)
                    .listRowSeparator(.hidden)
                }
                if !section.isCollapsed, let coordinator = hub.slot(for: section.id) {
                    ServerSessionRows(hub: hub, coordinator: coordinator, section: section,
                                      onShareQR: { ref in qrRef = ref; showQRSheet = true })
                } else if !section.isCollapsed, !section.sessions.isEmpty {
                    // Disabled or token-less bookmark with cached rows: plain, greyed, inert.
                    Section {
                        ForEach(section.sessions, id: \.id) { s in
                            Text(s.name ?? String(s.id.uuidString.prefix(8))).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        // Pinned, not inherited — see the pre-hub history of this view: the tiles
        // get their rounded corners from the inset-grouped section shape.
        .listStyle(.insetGrouped)
        .listSectionSpacing(WorkspaceTileMetrics.tileGap)
        .navigationTitle("Sessions")
        .sheet(isPresented: $showQRSheet) {
            if let ref = qrRef, let coordinator = hub.slot(for: ref.serverId) {
                QRCodeSheet(sessionId: ref.sessionId,
                            sessionName: coordinator.name(for: ref.sessionId),
                            serverInstanceId: hub.sections.first { $0.id == ref.serverId }?.config.instanceId)
            }
        }
        // Pull-to-refresh fans the wake transition out to every server, so it
        // doubles as the user's retry affordance.
        .refreshable { await hub.handleForegroundTransition(userInitiated: true) }
        .overlay {
            if hub.aggregate.enabledServers > 0, hub.aggregate.liveServers == 0, hub.sections.allSatisfy({ $0.sessions.isEmpty }) {
                ProgressView("Connecting…")
            }
        }
        .sheet(isPresented: $showAttachSheet) {
            if let focus = hub.focusCoordinator {
                AttachSessionSheet(sessions: attachableSessions, coordinator: focus, isPresented: $showAttachSheet)
            }
        }
    }
}

/// One server's rows: the workspace tiles and session rows exactly as the
/// single-server sidebar drew them. Rows at half opacity when the section is
/// cached (offline). Tap → `hub.select(ref)`; swipe → terminate on that server.
private struct ServerSessionRows: View {
    @ObservedObject var hub: IOSServerHub
    @ObservedObject var coordinator: SessionCoordinator
    let section: ServerSection
    let onShareQR: (SessionRef) -> Void
    @State private var collapse = SidebarCollapseModel()

    var body: some View {
        let sessions = section.sessions
        let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        ForEach(coordinator.activityCoordinator.rollups(for: sessions)) { group in
            let members = group.sessionIds.compactMap { byId[$0] }
            let collapsed = collapse.isCollapsed(group.id) || members.isEmpty
            Section {
                WorkspaceTileHeader(group: group, isCollapsed: collapsed) {
                    collapse.toggle(group.id)
                    coordinator.saveCollapsedGroups(collapse.collapsedGroupIds)  // F3
                }
                .workspaceTileRow(collapsed ? .only : .top)
                if !collapsed {
                    ForEach(Array(members.enumerated()), id: \.element.id) { index, session in
                        let ref = SessionRef(serverId: section.id, sessionId: session.id)
                        SessionRow(
                            session: session,
                            name: coordinator.name(for: session.id),
                            isActive: hub.activeRef == ref,
                            activity: coordinator.activityState(for: session.id),
                            agentId: coordinator.activeAgent(for: session.id),
                            agentState: coordinator.agentState(for: session.id),
                            seen: !coordinator.isUnseen(session.id),
                            onRename: { newName in coordinator.setName(newName, for: session.id) },
                            onShareQR: { onShareQR(ref) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await hub.select(ref) } }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await coordinator.terminateSession(id: session.id) }
                            } label: { Label("Kill", systemImage: "xmark.circle") }
                        }
                        .workspaceTileRow(.forSession(index: index, of: members.count))
                        .opacity(section.isCached ? 0.5 : 1)
                    }
                }
            }
        }
        .onAppear { collapse = SidebarCollapseModel(collapsed: coordinator.loadCollapsedGroups()) }
    }
}
```

Two follow-on edits in the same file:
- `QRScannerSheet.handleScannedCode` must route through the hub: replace `Task { await coordinator.attachRemoteSession(id: sessionId) }` with `Task { _ = await hub.handleDeepLink(link) }` where `link = SessionDeepLink(string: value)` — this gives the scanner the instance-id routing for free. Change `QRScannerSheet` to take `hub: IOSServerHub` instead of `coordinator`, and `AttachSessionSheet` to pass `hub` through (it keeps `coordinator` for the remote-attach list).
- `QRCodeSheet` gains `serverInstanceId: UUID? = nil` and builds its string with `SessionDeepLink(sessionId: sessionId, serverInstanceId: serverInstanceId).urlString` (in `CodeRelayApp/Views/QRCodeSheet.swift` line 10 and the matching `QRCodeComponents.swift:40` helper — pass the parameter through). Scanned on another device, the link now routes by relay identity (spec §10).

- [ ] **Step 4: Build and run the tests**

Run: `xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CodeRelayAppTests/SidebarSectionsTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed|error:|failed" | tail -4`
Expected: 2 tests, 0 failures (after Task 5 compiles — see Task 3 Step 7's ruling).

- [ ] **Step 5: Commit**

```bash
git add CodeRelayApp/Views/SessionSidebarView.swift CodeRelayApp/Views/QRCodeSheet.swift CodeRelayApp/Views/Components/QRCodeComponents.swift CodeRelayAppTests/SidebarSectionsTests.swift
git commit -m "feat(ios): sidebar grouped by server with status headers and cached offline rows

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: iOS — `ActiveTerminalView(hub:)` with a cross-server tab strip

**Files:**
- Modify: `CodeRelayApp/Views/ActiveTerminalView.swift`
- Create: `CodeRelayAppTests/SessionTabStripTests.swift`

**Interfaces:**
- Consumes: `hub.activeCoordinator`, `hub.activeRef`, `hub.sections`, `hub.orderedRefs`, `hub.slot(for:)`, `hub.select(_:)`, `hub.isShowingServerList`; `TerminalHostView(coordinator:fontSize:isKeyboardVisible:)`, `SessionLoadingOverlay`, `WandButton`, `TerminalReloadFade`, `QRCodeOverlay`, `KeyboardAccessory`, `ConnectionQualityDot` (unchanged).
- Produces: `ActiveTerminalView(hub:columnVisibility:)`; pure `SessionTabStripModel.tabs(sections:activeRef:) -> [Tab]` where `Tab { ref, number, isSelected, serverTitle: String? (nil when one enabled server) }`; `ActiveTerminalView.hostKey(for:) -> ObjectIdentifier?`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import CodeRelayClient
import CodeRelayKit
@testable import CodeRelayApp

@MainActor
final class SessionTabStripTests: XCTestCase {
    private func section(_ name: String, _ status: ServerSectionStatus, enabled: Bool = true, sessions: Int) -> ServerSection {
        var c = ConnectionConfig(name: name, host: name); c.enabled = enabled
        let list = (0..<sessions).map { _ in SessionInfo(id: UUID(), state: .activeDetached, tokenId: "t", createdAt: Date(), cols: 80, rows: 24) }
        return ServerSection(config: c, status: status, sessions: list, isCached: !status.isLive, rollups: [], awaitingInput: 0, isCollapsed: false)
    }

    func testTabsNumberAcrossServersInSidebarOrderAndSkipDisabled() {
        let a = section("a", .live, sessions: 2), b = section("b", .live, sessions: 1), c = section("c", .disabled, enabled: false, sessions: 3)
        let active = SessionRef(serverId: b.id, sessionId: b.sessions[0].id)
        let tabs = SessionTabStripModel.tabs(sections: [a, b, c], activeRef: active)
        XCTAssertEqual(tabs.map(\.number), [1, 2, 3], "numbers run across servers like ⌘1…9 on the Mac")
        XCTAssertEqual(tabs.map(\.ref.serverId), [a.id, a.id, b.id], "a disabled server's cached rows are not tabs")
        XCTAssertEqual(tabs.map(\.isSelected), [false, false, true])
        XCTAssertEqual(tabs.map(\.serverTitle), ["a", "a", "b"], "several servers: tabs carry the server name for the accessibility label")
    }

    func testOneEnabledServerHasNoServerTitle() {
        let a = section("a", .live, sessions: 1), c = section("c", .disabled, enabled: false, sessions: 1)
        XCTAssertEqual(SessionTabStripModel.tabs(sections: [a, c], activeRef: nil).map(\.serverTitle), [nil], "G8: a one-server user sees no prefix")
    }

    func testTerminalHostKeyChangesAcrossServers() {
        // A cross-server switch must rebuild the host (SwiftTerm keeps hosting the
        // old coordinator's view otherwise); within one server the host is reused.
        let x = IOSServerHubFactory.makeCoordinator(config: ConnectionConfig(name: "x", host: "x"), token: "t")
        let y = IOSServerHubFactory.makeCoordinator(config: ConnectionConfig(name: "y", host: "y"), token: "t")
        XCTAssertEqual(ActiveTerminalView.hostKey(for: x), ActiveTerminalView.hostKey(for: x))
        XCTAssertNotEqual(ActiveTerminalView.hostKey(for: x), ActiveTerminalView.hostKey(for: y))
        XCTAssertNil(ActiveTerminalView.hostKey(for: nil))
        x.tearDown(); y.tearDown()
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Expected on build: `cannot find 'SessionTabStripModel' in scope`, `type 'ActiveTerminalView' has no member 'hostKey'`.

- [ ] **Step 3: Implement**

Add above `ActiveTerminalView` in `ActiveTerminalView.swift`:

```swift
/// The session tab strip's rows, pure for tests (spec §8.2: tabs span servers).
enum SessionTabStripModel {
    struct Tab: Equatable {
        let ref: SessionRef
        let number: Int
        let isSelected: Bool
        /// Server name for the spoken label; nil when only one server is enabled (G8).
        let serverTitle: String?
    }

    static func tabs(sections: [ServerSection], activeRef: SessionRef?) -> [Tab] {
        let enabled = sections.filter(\.config.enabled)
        let titled = enabled.count > 1
        var number = 0
        return enabled.flatMap { section in
            section.sessions.map { session in
                number += 1
                let ref = SessionRef(serverId: section.id, sessionId: session.id)
                return Tab(ref: ref, number: number, isSelected: ref == activeRef, serverTitle: titled ? section.title : nil)
            }
        }
    }
}
```

Then change `ActiveTerminalView`:

```swift
struct ActiveTerminalView: View {
    @ObservedObject var hub: IOSServerHub
    @Binding var columnVisibility: NavigationSplitViewVisibility
    …(existing @State properties unchanged; `onDisconnect` is removed)…

    private var coordinator: SessionCoordinator? { hub.activeCoordinator }

    /// Keyed host: a cross-server switch swaps the whole SwiftTerm host; within
    /// one server the host is reused so each terminal's scrollback survives.
    static func hostKey(for coordinator: SessionCoordinator?) -> ObjectIdentifier? {
        coordinator.map(ObjectIdentifier.init)
    }
```

and in `body`:
- The `if let id = coordinator.activeSessionId, let vm = coordinator.viewModel(for: id)` becomes `if let coordinator, let id = coordinator.activeSessionId, let vm = coordinator.viewModel(for: id)`, and the `ZStack` gets `.id(Self.hostKey(for: coordinator))`.
- `WandButton(coordinator: coordinator, …)` inside `floatingButtons` needs a coordinator: make `floatingButtons` take it as a parameter (`private func floatingButtons(_ coordinator: SessionCoordinator) -> some View`).
- `ToolbarIconButton(icon: "server.rack") { onDisconnect() }` → `{ hub.isShowingServerList = true }` with `.accessibilityLabel("Servers")`.
- `ConnectionQualityDot(quality: coordinator.connection.connectionQuality, size: 8)` → `if let coordinator { ConnectionQualityDot(quality: coordinator.connection.connectionQuality, size: 8) }`.
- Every other `coordinator.` read becomes `coordinator?.` or sits inside `if let coordinator`; `anyTabNeedsFlash` iterates `SessionTabStripModel.tabs(sections: hub.sections, activeRef: hub.activeRef)` and asks `hub.slot(for: tab.ref.serverId)` for `agentState(for:)` / `sessionsAwaitingInput`.
- `sessionTabBar(flashOn:)` iterates the same tabs: `Button { Task { await hub.select(tab.ref) } } label: { SessionTab(number: tab.number, isSelected: tab.isSelected, agentId: slot?.activeAgent(for:), needsAttention:, flashOn:, agentState:) }.accessibilityLabel(tab.serverTitle.map { "\($0), session \(tab.number)" } ?? "Session \(tab.number)").id(tab.ref)`; the `scrollTo` calls use `hub.activeRef` as the id.
- The empty `ContentUnavailableView` reads: title `hub.aggregate.enabledServers == 0 ? "No Servers Enabled" : (hub.aggregate.liveServers == 0 ? "Connecting…" : "No Active Session")`, description `"Swipe from the left edge or create a new session."` unchanged, plus an actions button `Button("Servers") { hub.isShowingServerList = true }` when `enabledServers == 0`.
- `.onChange(of: coordinator.activeSessionId)` → `.onChange(of: hub.activeRef)`.
- The QR overlay passes `serverInstanceId: hub.sections.first { $0.id == hub.activeRef?.serverId }?.config.instanceId` through `QRCodeOverlay` (add the parameter in `QRCodeComponents.swift` alongside Task 4's change).

- [ ] **Step 4: Build and run every iOS test**

Run: `xcodegen generate && xcodebuild test -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests|error:|failed" | tail -4`
Expected: all CodeRelayAppTests pass (existing 4 files + `IOSServerHubTests` 4 + `WorkspaceRootTests` 4 + `SidebarSectionsTests` 2 + `SessionTabStripTests` 3).

Then the other gates: `swift test` (`EXIT=0`), the Mac build+test (49/49), the iOS simulator build.

- [ ] **Step 5: Commit**

```bash
git add CodeRelayApp/Views/ActiveTerminalView.swift CodeRelayApp/Views/Components/QRCodeComponents.swift CodeRelayAppTests/SessionTabStripTests.swift CodeRelay.xcodeproj/project.pbxproj
git commit -m "feat(ios): terminal pane hosts the hub's active coordinator; tab strip spans servers

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Debug seed, simulator verification, docs, gates, PR

**Files:**
- Modify: `CodeRelayApp/Debug/HubPreviewSeed.swift` (fill in the borrowed-token lookup), `CLAUDE.md` ("App Architecture" multi-server paragraph: iOS now included), `Sources/CodeRelayClient/CLAUDE.md` (one bullet: `connectionState` published)

- [ ] **Step 1: Seed — borrow the loopback token like the Mac seed**

In `HubPreviewSeed.makeStores`, replace `Tokens(tokenId: list[0].id, borrowed: nil)` with `Tokens(tokenId: list[0].id, borrowed: borrowLoopbackToken())` and add:

```swift
    /// The first bookmark borrows the real token of the user's loopback bookmark
    /// when there is one — a made-up token would burn the local relay's auth
    /// budget (10 failures / 60 s blocks the IP). On a simulator there is
    /// usually none, so the first section renders authFailed; that is fine.
    private static func borrowLoopbackToken() -> String? {
        CodeRelayApp.savedConnections.loadAll()
            .first(where: { ["127.0.0.1", "localhost", "::1"].contains($0.host) })
            .flatMap { try? AuthManager.shared.loadToken(for: $0.id) }
    }
```

- [ ] **Step 2: Simulator verification (screenshots + deep link)**

```bash
xcrun simctl boot "iPhone 16" 2>/dev/null; xcrun simctl bootstatus "iPhone 16" -b
xcodebuild build -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath build/ios-sim CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD"
APP=$(find build/ios-sim -name "CodeRelayApp.app" -path "*iphonesimulator*" | head -1)
xcrun simctl install "iPhone 16" "$APP"
SIMCTL_CHILD_CODERELAY_HUB_SEED=1 xcrun simctl launch "iPhone 16" com.claude.relay
sleep 6; xcrun simctl io "iPhone 16" screenshot /tmp/ios-hub-01-terminal-empty.png
# The sidebar sheet opens itself when nothing is selected; the management sheet when nothing is enabled.
xcrun simctl openurl "iPhone 16" "coderelay://session/$(uuidgen)?server=$(uuidgen)"
sleep 2; xcrun simctl io "iPhone 16" screenshot /tmp/ios-hub-02-deeplink-notfound.png
xcrun simctl spawn "iPhone 16" log show --last 2m --predicate 'subsystem == "com.coderelay.client"' --info | grep -E "hub|No token" | head
```

Expected: the first screenshot shows the sidebar sheet with three section headers (`studio` and `build-box` as auth-failed with a Retry/Re-pair affordance, `laptop` disabled) or, with no loopback bookmark on the simulator, both enabled sections `authFailed`; the second shows the "Session not found on any enabled server" notice capsule; the log shows the two `No token for bookmark … section marked authFailed` lines. Keep screenshots out of git. Describe them in words in the PR.

- [ ] **Step 3: Docs**

In `CLAUDE.md`'s multi-server paragraph change "**Multi-server (macOS first; …)**" to "**Multi-server (macOS and iOS; …)**" and append one sentence: "On iOS `CodeRelayApp` owns the hub (`IOSServerHubFactory`); `WorkspaceView(hub:)` is the root, `ServerListView(hub:)` the management sheet, the sidebar renders `ServerSectionHeader`s over the unchanged tiles, and the tab strip numbers sessions across servers (`SessionTabStripModel`); `scenePhase → .active` and `NetworkMonitor.connectivityRestored` fan out through `hub.handleForegroundTransition`, so the iOS coordinator no longer calls `startNetworkRecovery()`."

In `Sources/CodeRelayClient/CLAUDE.md`'s ServerHub section add: "- `SharedSessionCoordinator.connectionState` is `@Published`, mirrored from `connection.$state`; a computed property fired no `objectWillChange`, so without a subclass mirror (iOS) the hub never saw a dropped socket."

- [ ] **Step 4: Full gates**

Run: `swift build 2>&1 | tail -2; echo EXIT=${pipestatus[1]}` → `EXIT=0`
Run: `swift test > /tmp/p2_swift_test.log 2>&1; echo EXIT=$?; grep -c "' passed" /tmp/p2_swift_test.log; grep -c "' failed" /tmp/p2_swift_test.log` → `EXIT=0`, 0 failed.
Run the iOS tests, the iOS build, the Mac build+test (commands in Global Constraints) → all succeed.
Run swiftlint on the touched files and diff against `main` the way Plan 1 did (`git show main:<file>` into `/tmp/lint_base/`, strip line numbers and counts with `sed -E 's/[0-9]+/N/g'`, `comm -23`) → no new warnings.

- [ ] **Step 5: Commit and PR**

```bash
git add CodeRelayApp/Debug/HubPreviewSeed.swift CLAUDE.md Sources/CodeRelayClient/CLAUDE.md
git commit -m "docs(ios): multi-server notes and the iOS debug seed borrows the loopback token

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push -u origin feat/multi-server-plan2-ios
```

PR title: `feat(ios): multi-server workspace on ServerHub (plan 2)`. Body: Tasks 1–6 summary; compatibility note (one-server iOS users: the migration enables only the last-connected bookmark, the sidebar shows one section with no server prefix, the Servers screen is now a sheet with Enabled toggles instead of a Connect list; macOS unchanged except the shared `connectionState` publication); test inventory; simulator verification described in words. Wait for all four CI jobs; known macOS flakes get `gh run rerun --failed`.

---

### Task 7: Shared + iOS — one loading sheet for switch, refresh and reconnect; terminal fades to black underneath

**Files:**
- Modify: `Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift` (`switchToSession` ~line 778; `reloadTerminalFromServer` ~line 855)
- Create: `Sources/CodeRelayClient/Views/SessionLoadingPresentation.swift`, `Sources/CodeRelayClient/Views/SessionLoadingSheet.swift`
- Modify: `Sources/CodeRelayClient/Views/TerminalReloadFade.swift` (the cover is no longer driven here)
- Delete: `Sources/CodeRelayClient/Views/SessionLoadingOverlay.swift` (the inline veil; both apps move to the sheet — the Kotlin clients keep their own `SessionLoadingOverlay`, untouched)
- Modify: `CodeRelayApp/Views/WorkspaceView.swift`, `CodeRelayApp/Views/ActiveTerminalView.swift`
- Test: `Tests/CodeRelayClientTests/SharedSessionCoordinatorLoadPhaseTests.swift`, `Tests/CodeRelayClientTests/SessionLoadingPresentationTests.swift` (new)

**Interfaces:**
- Consumes: `SharedSessionCoordinator.sessionLoadPhase` (`SessionLoadPhase?`, published), `isRecovering`, `recoveryPhase` (`RecoveryPhase`, `.label`), `registerLiveTerminal(for:view:)`, `reloadTerminalFromServer(id:)`, `cancelRecovery()`; `TerminalViewModel.beginReplay/receiveOutput/endReplay` (for tests).
- Produces:
  - `SessionLoadingPresentation` (pure value): `init(loadPhase: SessionLoadPhase?, isRecovering: Bool, recoveryPhase: SharedSessionCoordinator.RecoveryPhase, sessionName: String?, serverName: String?)`; `isActive: Bool`; `title: String` ("Reconnecting" while recovering, else "Loading session"); `status: String` (the phase label, e.g. "Authenticating…", "Loading session history…"); `detail: String?` (formatted bytes while `loadingHistory`); `subtitle: String?` ("<session> · <server>"); `allowsCancel: Bool` (recovery only).
  - `SessionLoadingSheetModel` (`@MainActor final class, ObservableObject`): `@Published private(set) var isPresented`, `@Published private(set) var shown: SessionLoadingPresentation?` (the last active presentation, kept while the sheet animates down), `static let minimumVisible: Duration = .milliseconds(600)`, `func update(_ presentation: SessionLoadingPresentation)`, `init(sleep:)` for tests.
  - `SessionLoadingSheet(presentation:onCancel:)` SwiftUI view: spinner, title, status, **the byte counter as the largest text on the sheet** (`SessionLoadingSheet.bytesFont` = `.title2.monospacedDigit().weight(.semibold)`, `.numericText()` transition so the digits roll rather than flash; the slot is reserved from the first phase and reads "0 KB" until history starts, so the layout never jumps), subtitle, Cancel when `allowsCancel`.
  - `TerminalReloadFade.reload(coordinator:id:)` replaces `run(coordinator:id:cover:)`; `TerminalReloadFade.coverDuration` (0.16 s to black, 0.22 s back) and `View.terminalReloadCover(_:)` stay.
  - Coordinator: `switchToSession` publishes `.attaching` at its start on every path (also when the cached terminal lets it skip the replay); `reloadTerminalFromServer` publishes `.attaching` before its RPC and clears the phase in its `catch` (the replay hooks clear it on success as today).

- [ ] **Step 1: Write the failing coordinator tests**

Append to `SharedSessionCoordinatorLoadPhaseTests`:

```swift
    func testReloadFromServerPublishesAttachingThenClearsOnFailure() async {
        // The name-label tap must raise the sheet immediately, and a failed
        // resume (no controller here) must not leave it up.
        let coordinator = makeCoordinator()
        let id = UUID()
        _ = installVM(in: coordinator, id: id)
        coordinator.activeSessionId = id
        var seen: [SessionLoadPhase?] = []
        let sub = coordinator.$sessionLoadPhase.dropFirst().sink { seen.append($0) }
        defer { sub.cancel() }
        await coordinator.reloadTerminalFromServer(id: id)
        XCTAssertEqual(seen.first, .attaching, "sheet up at the tap, not at the first replay byte")
        XCTAssertNil(coordinator.sessionLoadPhase, "a failed reload clears the phase; the pane keeps its text")
    }

    func testSwitchPublishesAttachingEvenWithALiveTerminal() async {
        // A cached SwiftTerm view skips the replay, so nothing used to set the
        // phase: the switch was invisible. The sheet must rise on every switch.
        let coordinator = makeCoordinator()
        let from = UUID(), to = UUID()
        _ = installVM(in: coordinator, id: from)
        _ = installVM(in: coordinator, id: to)
        coordinator.registerLiveTerminal(for: to, view: NSObject())
        coordinator.activeSessionId = from
        var seen: [SessionLoadPhase?] = []
        let sub = coordinator.$sessionLoadPhase.dropFirst().sink { seen.append($0) }
        defer { sub.cancel() }
        await coordinator.switchToSession(id: to)      // no controller: the resume fails and rolls back
        XCTAssertEqual(seen.first, .attaching)
        XCTAssertNil(coordinator.sessionLoadPhase)
    }
```

- [ ] **Step 2: Write the failing presentation/model tests**

`Tests/CodeRelayClientTests/SessionLoadingPresentationTests.swift`:

```swift
import XCTest
@testable import CodeRelayClient

@MainActor
final class SessionLoadingPresentationTests: XCTestCase {
    private func make(_ phase: SessionLoadPhase?, recovering: Bool = false,
                      recovery: SharedSessionCoordinator.RecoveryPhase = .reconnecting) -> SessionLoadingPresentation {
        SessionLoadingPresentation(loadPhase: phase, isRecovering: recovering, recoveryPhase: recovery,
                                   sessionName: "Arya", serverName: "studio")
    }

    func testInactiveWhenNothingLoads() {
        XCTAssertFalse(make(nil).isActive)
    }

    func testLoadPhasesDriveTitleStatusAndBytes() {
        let p = make(.loadingHistory(bytes: 212_000))
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.title, "Loading session")
        XCTAssertEqual(p.status, "Loading session history…")
        XCTAssertEqual(p.detail, SessionLoadPhase.formatBytes(212_000))
        XCTAssertEqual(p.subtitle, "Arya · studio")
        XCTAssertFalse(p.allowsCancel)
        XCTAssertEqual(make(.authenticating).status, "Authenticating…")
        XCTAssertEqual(make(.attaching).detail, SessionLoadPhase.formatBytes(0),
                       "the counter slot is reserved from the first phase so the layout never jumps")
        XCTAssertNil(make(nil).detail)
    }

    func testBytesAreTheLargestTextOnTheSheet() {
        // The counter is the one line that proves progress is real; it must not
        // be a caption under the status.
        XCTAssertEqual(SessionLoadingSheet.bytesFont, .title2.monospacedDigit().weight(.semibold))
        XCTAssertEqual(SessionLoadingSheet.statusFont, .subheadline)
    }

    func testRecoveryWinsTheTitleAndOffersCancel() {
        let p = make(nil, recovering: true, recovery: .authenticating)
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.title, "Reconnecting")
        XCTAssertEqual(p.status, "Authenticating…")
        XCTAssertTrue(p.allowsCancel)
        // Recovery then resumes the session: the replay phase takes over the status line.
        XCTAssertEqual(make(.loadingHistory(bytes: 10), recovering: true, recovery: .resuming).status, "Loading session history…")
    }

    func testSheetHoldsAMinimumEvenWhenLoadingIsInstant() async {
        var sleeps: [Duration] = []
        var release: CheckedContinuation<Void, Never>?
        let model = SessionLoadingSheetModel(sleep: { d in sleeps.append(d); await withCheckedContinuation { release = $0 } })
        model.update(make(.attaching))
        XCTAssertTrue(model.isPresented, "up immediately on the first active presentation")
        model.update(make(nil))                              // loading finished 5 ms later
        XCTAssertTrue(model.isPresented, "held: a 5 ms sheet reads as a flicker")
        XCTAssertEqual(sleeps, [SessionLoadingSheetModel.minimumVisible])
        release?.resume(); release = nil
        await Task.yield(); try? await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(model.isPresented, "dismissed once the hold elapsed and nothing is loading")
        XCTAssertEqual(model.shown?.status, "Attaching to session…", "the text stays while the sheet animates down")
    }

    func testSheetStaysWhileLoadingOutlivesTheHold() async {
        var release: CheckedContinuation<Void, Never>?
        let model = SessionLoadingSheetModel(sleep: { _ in await withCheckedContinuation { release = $0 } })
        model.update(make(.attaching))
        release?.resume(); release = nil
        await Task.yield(); try? await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(model.isPresented, "the hold elapsed but the load is still running")
        model.update(make(.loadingHistory(bytes: 4096)))
        XCTAssertEqual(model.shown?.detail, SessionLoadPhase.formatBytes(4096))
        model.update(make(nil))
        await Task.yield()
        XCTAssertFalse(model.isPresented, "past the hold, dismissal is immediate")
    }

    func testPresentationClearsOnEveryTerminalPath() {
        // Recovery cancelled, auth rejected, replay never delivered: the inputs go
        // back to nil/false and the presentation must be inactive — the model
        // then dismisses. (Each producer's own tests prove it resets its input.)
        XCTAssertFalse(make(nil, recovering: false).isActive)
    }
}
```

Check `SessionLoadPhase.formatBytes` is `public static` (`grep -n "formatBytes" Sources/CodeRelayClient/ViewModels/SessionLoadPhase.swift`); make it so if it is internal.

- [ ] **Step 3: Run to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head -5`
Expected: `cannot find 'SessionLoadingPresentation' in scope`, `cannot find 'SessionLoadingSheetModel' in scope`; then after stubs exist, the two coordinator tests fail on `seen.first` being `nil`/absent.

- [ ] **Step 4: Implement the shared pieces**

`Sources/CodeRelayClient/Views/SessionLoadingPresentation.swift`:

```swift
import Foundation

/// What the loading sheet says, derived from the coordinator's two published
/// signals. One rule for the three ways a session reaches the screen — a
/// switch, the session-name refresh, a reconnect — so they look identical.
public struct SessionLoadingPresentation: Equatable {
    public let isActive: Bool
    public let title: String
    public let status: String
    /// Bytes loaded so far, formatted — nil only while nothing is loading.
    /// Reserved from the first phase ("0 KB") so the sheet's layout is stable and
    /// the user sees the counter start moving the moment history streams.
    public let detail: String?
    public let subtitle: String?
    public let allowsCancel: Bool

    public init(loadPhase: SessionLoadPhase?,
                isRecovering: Bool,
                recoveryPhase: SharedSessionCoordinator.RecoveryPhase,
                sessionName: String?,
                serverName: String?) {
        isActive = loadPhase != nil || isRecovering
        title = isRecovering ? "Reconnecting" : "Loading session"
        // The replay phase is the more specific status once it starts, even mid-recovery.
        status = loadPhase?.label ?? (isRecovering ? recoveryPhase.label : "")
        detail = isActive ? (loadPhase?.detail ?? SessionLoadPhase.formatBytes(0)) : nil
        let parts = [sessionName, serverName].compactMap { $0 }.filter { !$0.isEmpty }
        subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        allowsCancel = isRecovering
    }
}

/// Presents the sheet the instant something loads, holds it at least
/// `minimumVisible` so an instant switch still reads as a response rather
/// than a flicker, and dismisses it when nothing is loading any more. The
/// terminal blackout follows `isPresented` so sheet and black lift together.
@MainActor
public final class SessionLoadingSheetModel: ObservableObject {
    public static let minimumVisible: Duration = .milliseconds(600)

    @Published public private(set) var isPresented = false
    /// The last active presentation, kept while the sheet animates down.
    @Published public private(set) var shown: SessionLoadingPresentation?

    private var active = false
    private var holdElapsed = true
    private var holdTask: Task<Void, Never>?
    private let sleep: @MainActor (Duration) async -> Void

    public init(sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    public func update(_ presentation: SessionLoadingPresentation) {
        active = presentation.isActive
        if presentation.isActive { shown = presentation }
        if active, !isPresented {
            isPresented = true
            holdElapsed = false
            holdTask?.cancel()
            holdTask = Task { [weak self] in
                guard let self else { return }
                await self.sleep(Self.minimumVisible)
                guard !Task.isCancelled else { return }
                self.holdElapsed = true
                self.settle()
            }
        }
        settle()
    }

    private func settle() {
        if isPresented, !active, holdElapsed { isPresented = false }
    }
}
```

`Sources/CodeRelayClient/Views/SessionLoadingSheet.swift`:

```swift
import SwiftUI

/// The bottom sheet shown while a session is on its way to the screen. Hosted
/// by both apps (iOS as a detented sheet, macOS as a window sheet).
public struct SessionLoadingSheet: View {
    public let presentation: SessionLoadingPresentation
    public let onCancel: (() -> Void)?

    public init(presentation: SessionLoadingPresentation, onCancel: (() -> Void)? = nil) {
        self.presentation = presentation
        self.onCancel = onCancel
    }

    /// The byte counter is deliberately the largest text on the sheet: it is
    /// the one line that proves the load is progressing.
    public static let bytesFont: Font = .title2.monospacedDigit().weight(.semibold)
    public static let statusFont: Font = .subheadline

    public var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(presentation.title).font(.headline)
            if let detail = presentation.detail {
                Text(detail)
                    .font(Self.bytesFont)
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.2), value: detail)
                    .accessibilityLabel("\(detail) loaded")
            }
            Text(presentation.status)
                .font(Self.statusFont)
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: presentation.status)
            if let subtitle = presentation.subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(.tertiary).lineLimit(1)
            }
            if presentation.allowsCancel, let onCancel {
                Button("Cancel", role: .cancel) { onCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
```

`TerminalReloadFade.swift`: replace `run(coordinator:id:cover:)` with

```swift
    /// The session-name tap: reload the pane from the server's scrollback. The
    /// coordinator publishes `.attaching` first, which raises the loading sheet
    /// and the blackout; the replay hooks clear it on the first visible frame.
    public static func reload(coordinator: SharedSessionCoordinator, id: UUID) async {
        await coordinator.reloadTerminalFromServer(id: id)
        if let vm = coordinator.viewModel(for: id) { await waitForReloadToLand(vm) }
    }
```

keeping `waitForReloadToLand`, the two durations (now named `coverOutDuration`/`coverInDuration`, both still public) and the `terminalReloadCover` extension. Delete `SessionLoadingOverlay.swift`.

Coordinator (`SharedSessionCoordinator.swift`): in `switchToSession`, move `sessionLoadPhase = .attaching` out of the `if !hasLiveTerminal` block so it runs on every switch (keep `beginReplay()` inside it); the existing `if hasLiveTerminal { sessionLoadPhase = nil }` after the resume and the `catch`'s `sessionLoadPhase = nil` already clear it. In `reloadTerminalFromServer`, add `sessionLoadPhase = .attaching` right after `vm.beginServerReload()` and `sessionLoadPhase = nil` in the `catch` before `vm.cancelServerReload()`. Update the doc comment on `sessionLoadPhase`'s declaration to say it is set for every switch and reload.

- [ ] **Step 5: iOS adoption**

`WorkspaceView`: add `@StateObject private var loading = SessionLoadingSheetModel()`, pass it to `ActiveTerminalView(hub:columnVisibility:loading:)`, and drive it from the focus coordinator inside `FocusCoordinatorModifiers` (which already observes that coordinator):

```swift
    // in FocusCoordinatorModifiers
    @ObservedObject var loading: SessionLoadingSheetModel
    private var presentation: SessionLoadingPresentation {
        SessionLoadingPresentation(loadPhase: coordinator.sessionLoadPhase,
                                   isRecovering: coordinator.isRecovering,
                                   recoveryPhase: coordinator.recoveryPhase,
                                   sessionName: coordinator.activeSessionId.map { coordinator.name(for: $0) },
                                   serverName: serverName)
    }
    // body: replace the `.sheet(isPresented: $coordinator.isRecovering)` RecoveryOverlay with
            .onChange(of: presentation, initial: true) { _, p in loading.update(p) }
            .sheet(isPresented: Binding(get: { loading.isPresented }, set: { _ in })) {
                if let shown = loading.shown {
                    SessionLoadingSheet(presentation: shown,
                                        onCancel: shown.allowsCancel ? { coordinator.cancelRecovery() } : nil)
                        .presentationDetents([.fraction(0.32)])
                        .presentationDragIndicator(.hidden)
                        .presentationBackgroundInteraction(.disabled)
                        .interactiveDismissDisabled()
                        // Full width, not the safe area: see the iPhone Duo note that used to live on RecoveryOverlay.
                        .ignoresSafeArea(.container, edges: .horizontal)
                }
            }
```

Delete `RecoveryOverlay` from `WorkspaceView.swift` (nothing else uses it: `grep -rn RecoveryOverlay CodeRelayApp`).

`ActiveTerminalView`: add `@ObservedObject var loading: SessionLoadingSheetModel`; remove `SessionLoadingOverlay(...)` from the `ZStack`; the cover becomes

```swift
                    .terminalReloadCover(loading.isPresented ? 1 : 0)
                    .animation(.easeOut(duration: loading.isPresented ? TerminalReloadFade.coverOutDuration
                                                                      : TerminalReloadFade.coverInDuration),
                               value: loading.isPresented)
```

and the name-label tap becomes `Task { await TerminalReloadFade.reload(coordinator: coordinator, id: id) }`; delete the `reloadCover` `@State`. The sheet comes up from the bottom and the pane goes black together; when the coordinator clears the phase on the first visible frame, the model dismisses (after the hold) and both lift together.

- [ ] **Step 6: Run the tests and gates**

Run: `swift test --filter "SharedSessionCoordinatorLoadPhaseTests|SessionLoadingPresentationTests" 2>&1 | grep -E "Executed|error:|failed" | tail -4; echo EXIT=${pipestatus[1]}` → `EXIT=0`, 7 + 6 tests.
Then the iOS tests, the iOS build, and — because `SessionLoadingOverlay`, `TerminalReloadFade.run` and `RecoverySheet` are still referenced by `CodeRelayMac/Views/MainWindow.swift` — **the Mac build fails until Task 8**. Do Task 8 in the same build cycle (ruling, same shape as Tasks 3–5) and commit them as two commits.

- [ ] **Step 7: Commit**

```bash
git add Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift Sources/CodeRelayClient/Views/SessionLoadingPresentation.swift Sources/CodeRelayClient/Views/SessionLoadingSheet.swift Sources/CodeRelayClient/Views/TerminalReloadFade.swift Tests/CodeRelayClientTests/SharedSessionCoordinatorLoadPhaseTests.swift Tests/CodeRelayClientTests/SessionLoadingPresentationTests.swift CodeRelayApp/Views/WorkspaceView.swift CodeRelayApp/Views/ActiveTerminalView.swift
git rm -q Sources/CodeRelayClient/Views/SessionLoadingOverlay.swift
git commit -m "feat(client,ios): one loading sheet for switch, refresh and reconnect; the terminal fades to black underneath

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: macOS — adopt the same loading sheet (parity)

**Files:**
- Modify: `CodeRelayMac/Views/MainWindow.swift` (`ActiveCoordinatorModifiers`, the `detail` ZStack, `sessionNameLabel`, delete `RecoverySheet`)

**Interfaces:**
- Consumes: Task 7's `SessionLoadingPresentation`, `SessionLoadingSheetModel`, `SessionLoadingSheet`, `TerminalReloadFade.reload(coordinator:id:)`, `coverOutDuration`/`coverInDuration`; `hub.focusCoordinator`, `hub.focusServerId`, `hub.sections`.
- Produces: nothing new; the Mac shows the identical sheet (as a window sheet, fixed 320×220) and blackout.

- [ ] **Step 1: Write the failing test**

Append to `CodeRelayMacTests/MacServerHubTests.swift` (replacing the vacuous `testRegistryExposesTheActiveCoordinatorOfTheHub`, which asserts nothing about a hub — note the swap in the ledger):

```swift
    func testLoadingPresentationNamesTheFocusServer() {
        // The Mac sheet reads the same presentation as iOS; the server name is
        // the section title of the focus server.
        let p = SessionLoadingPresentation(loadPhase: .attaching, isRecovering: false, recoveryPhase: .reconnecting,
                                           sessionName: "Arya", serverName: "studio")
        XCTAssertEqual(p.subtitle, "Arya · studio")
        XCTAssertEqual(MainWindowLoading.detentSize, CGSize(width: 320, height: 220))
    }
```

- [ ] **Step 2: Run to verify it fails**

Expected: `cannot find 'MainWindowLoading' in scope` (the Mac build also fails on the Task 7 removals until Step 3).

- [ ] **Step 3: Implement**

In `MainWindow.swift`:
- Add `enum MainWindowLoading { static let detentSize = CGSize(width: 320, height: 220) }` (file scope, internal).
- `WorkspaceView` gains `@StateObject private var loading = SessionLoadingSheetModel()`; remove `@State private var reloadCover`; the detail `ZStack` drops `SessionLoadingOverlay(...)` and its `.terminalReloadCover(reloadCover)` becomes the same `loading.isPresented`-driven cover + animation as iOS (Task 7 Step 5).
- `ActiveCoordinatorModifiers(coordinator: focus, …)` gains `loading: loading` and `serverName: hub.sections.first { $0.id == hub.focusServerId }?.title`; inside it replace the `.sheet(isPresented: $coordinator.isRecovering) { RecoverySheet(...) }` with the same `.onChange(of: presentation, initial: true)` + `.sheet(isPresented:)` pair as iOS, with `.frame(width: MainWindowLoading.detentSize.width, height: MainWindowLoading.detentSize.height)` instead of the detent modifiers. Delete `RecoverySheet`.
- `sessionNameLabel`'s tap: `Task { await TerminalReloadFade.reload(coordinator: coordinator, id: id) }`.

- [ ] **Step 4: Gates**

Mac build-for-testing + test-without-building → `TEST EXECUTE SUCCEEDED`, 49 tests (48 + this one, minus none); `swift test` `EXIT=0`; iOS tests + build green.

- [ ] **Step 5: Commit**

```bash
git add CodeRelayMac/Views/MainWindow.swift CodeRelayMacTests/MacServerHubTests.swift
git commit -m "feat(mac): adopt the shared loading sheet and blackout for switch, refresh and reconnect

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Then fold "Task 7/8" into Task 6's docs step: in `CLAUDE.md`'s "Session-loading overlay" paragraph, rename it "**Session-loading sheet.**" and rewrite the first sentences: "Opening a session is black until the replay is delivered in one batch. Every path that brings a session to the screen — `switchToSession` (also when a cached terminal skips the replay), the session-name reload, recovery — publishes `sessionLoadPhase` from its first line, and `SessionLoadingSheetModel` (CodeRelayClient/Views) turns that plus `isRecovering` into a bottom sheet both apps present, held for at least 600 ms so an instant switch does not flicker, while the terminal fades to black behind it; both lift together on the first visible frame (`onReplayDelivered`). The inline `SessionLoadingOverlay` is gone on Apple platforms; the Kotlin clients still have theirs." Keep the rest of the paragraph (hooks, `pendingRestoreSessionId`) as is.

---

## Follow-ups this plan creates for Plans 3 and 4 (user request, 2026-10-28: "implement these changes in all clients")

The Kotlin clients (Android `CodeRelayAndroid/`, Linux `CodeRelayLinux/`) compile one copy of `feature-workspace`, so one implementation covers both:

- **Loading sheet, same rules as Task 7:** a `SessionLoadingPresentation` (Kotlin data class in `core-session`) from `TerminalSessionVm`'s load phase + `SessionCoordinator.isRecovering`/recovery phase; a `SessionLoadingSheetModel` with the 600 ms minimum hold; a Compose `ModalBottomSheet` (Android) / `Dialog` anchored bottom (Linux) with the byte counter as the largest text, reserved from the first phase ("0 KB"); the terminal `Box` fades to black under it with the same 0.16 s / 0.22 s curves; the existing Compose `SessionLoadingOverlay` is removed. The load phase must be published at the START of every switch (also when the local terminal buffer lets the resume skip the replay) and of the session-name reload, and cleared on every failure path.
- **Multi-server (spec §8.4, §8.5):** the Kotlin `ServerHub` with the same semantics as the Swift one (one `pendingRef == activeRef`, `selectionGeneration`, reconcile from the coordinator, concurrent start/fan-out, `focusCoordinator`, cap on reload, push unregister on disable, lenient bookmark decoding), grouped sidebar, management screen with Enabled toggles, deep-link routing (Android: FCM taps with `?server=`; Linux: `coderelay://` via `SingleInstance`), one-time migration of `lastConnectedServerId`.

## Self-review notes

- **Loading sheet (user request, 2026-10-28):** one presentation for switch / name-label refresh / reconnect (T7 shared model + iOS, T8 macOS); the byte counter is the largest text on the sheet, reserved from the first phase ("0 KB") and rolling with `.numericText()`; "always" is honoured by setting the phase at the start of every switch and reload and by the 600 ms minimum hold; the sheet dismisses and the black lifts on the first visible frame; every failure path clears the inputs (Review Focus 0).
- **Spec coverage (§8.1, §8.2, §9, §10, §11, §15.3):** root is the workspace (T3), sections + header + cached rows (T4), `hub.select` on tap (T4), New in the section header (T4), management screen with Enabled/duplicate/instance id and no Connect (T3), Reconnecting sheet names the server and shows for the focus coordinator only (T3), auth failure → Re-pair opens management (T4), Auto Connect setting removed and `lastConnectedServerId` retired by the migration (T2/T3), deep links routed by the hub and queued before start (T3), scenePhase fan-out (T3), QR share carries `?server=` (T4/T5), debug seed + `simctl openurl` (T6).
- **Placeholders:** none; where a signature must be confirmed the step names the exact `grep`.
- **Type consistency:** `IOSServerHub`, `IOSServerHubFactory.make/makeCoordinator/lastServerIdKey` (T2) used by T3–T6; `SessionSidebarView.rows/retryAction` (T4); `SessionTabStripModel.tabs` and `ActiveTerminalView.hostKey` (T5); `DeepLinkRouter`, `WorkspaceRoot.shouldPresentManagement`, `RecoveryOverlay(phase:serverName:onCancel:)` (T3); `QRCodeSheet(sessionId:sessionName:serverInstanceId:)` (T4, used by T5's overlay through `QRCodeComponents`).
- **Review Focus:** each of the five lines names the test that pins it.
- **Known coupling:** Tasks 7 and 8 compile only together (the Mac window references the removed overlay, fade and recovery sheet until it adopts the new ones); Tasks 3, 4 and 5 compile only together (the root view references the new sidebar and terminal initializers). Execute them in one build cycle and commit per task, with a ledger ruling — the same shape as Plan 1 Tasks 8/9.
