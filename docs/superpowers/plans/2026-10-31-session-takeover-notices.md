# Session Takeover Notices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every client tells the user — once, in one aggregated message — which sessions were attached from another device or ended while it was away, whether it was in the foreground, backgrounded, or killed, across every enabled server.

**Architecture:** A pure classifier turns "sessions I showed before" + the token-scoped list (+ `session_list_all` only when something is missing) into `taken` / `ended`. The diff runs wherever a list is applied (Swift `reconcile`, Kotlin `applyServerSessions`) against a per-server persisted baseline. Coordinators no longer present alerts; they report to a hub-level `SessionLossCollector` that dedupes, holds through a foreground fan-out (each slot's `awaitPassFinished`), and publishes one alert (taken) and one notice (ended) that the workspace root shows. A new `session_ended` server push (protocol v4) lets a connected client drop a session that exits live, silently.

**Tech Stack:** Swift 6.2 / SwiftUI / XCTest (CodeRelayKit, CodeRelayServer, CodeRelayClient, iOS + macOS apps); Kotlin / Compose / JUnit (CodeRelayAndroid `core-protocol`, `core-net`, `core-session`, `core-storage`, `feature-workspace`, `app`; CodeRelayLinux `linux-storage`, `app`).

**Spec:** `docs/superpowers/specs/2026-10-31-session-takeover-notices-design.md`

## Global Constraints

- **Copy, verbatim.** Taken alert title `Session Moved` (1) / `Sessions Moved` (2+). Bodies: `<A> was attached from another device.` · `<A> and <B> were attached from another device.` · `<A>, <B> and <N> others were attached from another device.` Ended notice: `<A> ended while you were away.` · `<A> and <B> ended while you were away.` · `<A>, <B> and <N> others ended while you were away.` Multi-server suffix after each name: ` (on <server display name>)`, only when one message spans more than one server. N is the remaining count ("2 others"; for exactly one remaining use `1 other`).
- **Timings:** live debounce 1 s; fan-out hold cap 10 s; repeat suppression 120 s.
- **Protocol:** `CodeRelayKit.protocolVersion` and Kotlin `ProtocolVersions.CURRENT` go 3 → 4. New server message type string `session_ended`, payload `{sessionId, reason}`, reason ∈ `exited` | `terminated` | `expired`. Must be unique across `ClientMessage`/`ServerMessage` type strings. Old clients drop unknown types already (Swift `RelayConnection.swift:519`, Kotlin `RelayConnection.kt:451`).
- **Ended is reported only when the server speaks v4** (`serverProtocolVersion >= 4`). Against a v3 relay, ended sessions leave the pane silently, as today — a v3 relay cannot tell the client about a live exit, so "while you were away" could be false.
- **Baseline is a diff baseline only.** It never populates the pane; the token-scoped list stays the only source for rendering (`SessionOwnershipStore` header rule).
- **No app version bumps** (release skill owns them). New Mac/iOS app source files need `xcodegen generate` with the regenerated `project.pbxproj` committed in the same task. New files under `Sources/` need nothing.
- **Never** run the relay binary directly, `pkill` it, or `claude-relay restart` — live sessions run in it. `git add` explicit paths only.
- **Gates per task** — run the ones the task touches; all green before commit:
  - Swift: `swift test 2>&1 | tail -5; echo EXIT=${pipestatus[1]}` → `EXIT=0`.
  - iOS: `xcodebuild build -project CodeRelay.xcodeproj -scheme CodeRelayApp -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`.
  - Mac: `xcodebuild build -project CodeRelay.xcodeproj -scheme CodeRelayMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
  - Kotlin (Android): `cd CodeRelayAndroid && JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :core-protocol:test :core-net:testDebugUnitTest :core-session:testDebugUnitTest :app:assembleDebug`.
  - Kotlin (Linux): `cd CodeRelayLinux && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :linux-storage:test :app:compileKotlin`.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Launch + scenePhase + network-restored inside ~100 ms** (cold launch, the commonest path): one alert, not three, and not zero because the hub flushed before the in-flight handshake reported. Task 5 `testFanOutWaitsForPassAlreadyInFlight`; Task 10 mirror.
2. **A queued `session_stolen` delivered on resume while the wake diff runs** — same session reported twice. Task 5 `testRepeatWithin120sIsSuppressed` and Task 4 `testLiveStealThenDiffReportsOnce`.
3. **User terminates a session on this device, then backgrounds** — must never be announced. Task 4 `testLocallyTerminatedSessionIsNeverReported`; Task 9 mirror.
4. **Bookmark edited to a new token / re-paired** — every old session would classify as taken by "another device". Task 4 `testTokenChangeDiscardsBaselineSilently`; Task 9 mirror.
5. **The active session is stolen on a non-first server with two servers enabled** — focus moves away; the alert must still show. Task 5 `testStealOnNonFocusedServerSurfaces`; Task 6 binds the alert to the hub, never to `focusCoordinator`.

---

### Task 1: Server + Kit — `session_ended` push, protocol v4

**Files:**
- Modify: `Sources/CodeRelayKit/CodeRelayKit.swift:8` (`protocolVersion = 4`)
- Modify: `Sources/CodeRelayKit/Protocol/ServerMessage.swift` (new case, type string, `allTypeStrings`, encode/decode)
- Modify: `Sources/CodeRelayServer/Actors/SessionManager.swift` (end observers; report from `handlePTYExit` ~689, `terminateSession` ~342, `handleDetachTimeout` ~789)
- Modify: `Sources/CodeRelayServer/Network/RelayMessageHandler.swift` (install observer next to the steal observer ~469; remove in cleanup ~795)
- Test: `Tests/CodeRelayKitTests/ServerMessageTests.swift`, `Tests/CodeRelayServerTests/SessionOwnershipTests.swift`, `Tests/CodeRelayServerTests/WireIntegrationTests.swift`

**Interfaces:**
- Produces: `ServerMessage.sessionEnded(sessionId: UUID, reason: String)` ↔ `"session_ended"`; `SessionManager.addEndObserver(tokenId: String, callback: @escaping (UUID, String) -> Void) -> UUID`, `removeEndObserver(id: UUID)`; `CodeRelayKit.protocolVersion == 4`.

- [ ] **Step 1: Failing tests.**
  - `ServerMessageTests.testSessionEndedRoundTrips`: encode `.sessionEnded(sessionId: id, reason: "exited")` → JSON type `"session_ended"`, decode back equal; `ServerMessage.allTypeStrings` contains it and is disjoint from `ClientMessage.allTypeStrings`.
  - `SessionOwnershipTests.testEndObserverFiresOnPTYExitTerminateAndExpiry`: three sessions owned by token `T`; an end observer on `T` and one on `U`; exit (mock PTY exit), terminate, and detach-timeout one each → `T` observer receives `(id1,"exited")`, `(id2,"terminated")`, `(id3,"expired")`; `U` receives nothing; a removed observer receives nothing.
  - `WireIntegrationTests.testOwnerReceivesSessionEndedWhenNotAttached`: client authenticates, creates then detaches a session, server-side PTY exits → client receives `session_ended` with `reason "exited"`.
- [ ] **Step 2:** `swift test --filter 'ServerMessageTests|SessionOwnershipTests|WireIntegrationTests'` → the three new tests fail.
- [ ] **Step 3: Implement.** End observers use the existing `ObserverRegistry` pattern (`stealObservers`), included in `purgeStale` and the observer count. Report **after** the state transition is committed, keyed by `managed.info.tokenId`. `terminateSession` reports `"terminated"` for both client and admin callers. The handler forwards on the event loop exactly like the steal observer (`UnsafeTransfer`), and does not exclude its own connection (the requester just drops an already-removed id).
- [ ] **Step 4:** Swift gate → `EXIT=0`.
- [ ] **Step 5: Commit** `feat(server): push session_ended to the owning token (protocol v4)`.

### Task 2: Swift — classifier and copy (pure)

**Files:**
- Create: `Sources/CodeRelayClient/Hub/SessionLoss.swift`
- Test: `Tests/CodeRelayClientTests/Hub/SessionLossTests.swift`

**Interfaces:**
- Produces:
  - `public struct LostSession: Equatable, Sendable { public let id: UUID; public let name: String }`
  - `public enum SessionLossKind: Sendable { case taken, ended }`
  - `public enum SessionLossClassifier { public static func lost(before: [LostSession], owned: [SessionInfo]) -> [LostSession]; public static func classify(lost: [LostSession], all: [SessionInfo]?, myTokenId: String) -> (taken: [LostSession], ended: [LostSession]) }`
  - `public struct SessionLossItem: Equatable, Sendable { public let serverId: UUID; public let serverName: String; public let session: LostSession }`
  - `public enum SessionLossCopy { public static func takenTitle(count: Int) -> String; public static func takenBody(_ items: [SessionLossItem]) -> String; public static func endedBody(_ items: [SessionLossItem]) -> String }`

- [ ] **Step 1: Failing tests.**
  - `testLostIncludesMissingAndTerminal`: before [A,B,C]; owned [A active, B `.exited`] → lost [B, C] (before order).
  - `testClassifyTakenVsEnded`: all has B non-terminal with tokenId `other`, C absent → taken [B], ended [C]; B with tokenId == mine → ended; B terminal in all → ended.
  - `testClassifyNilAllMeansTaken`: `all: nil` → everything taken.
  - `testCopyOneTwoMany`: exact Global Constraints strings for 1, 2, 3 (`and 1 other`), 4 (`and 2 others`); titles `Session Moved` / `Sessions Moved`.
  - `testServerSuffixOnlyWhenMixed`: two items same server → no suffix; different servers → `Renly (on mac-mini) and Stannis (on studio) were attached from another device.`
- [ ] **Step 2:** `swift test --filter SessionLossTests` → fail (types missing).
- [ ] **Step 3: Implement** in `SessionLoss.swift`. `lost` = `before` entries not present as non-terminal in `owned`, order preserved.
- [ ] **Step 4:** `swift test --filter SessionLossTests` → pass.
- [ ] **Step 5: Commit** `feat(client): session-loss classifier and copy`.

### Task 3: Swift — persisted baseline

**Files:**
- Modify: `Sources/CodeRelayClient/Helpers/SessionOwnershipStore.swift`
- Test: `Tests/CodeRelayClientTests/SessionOwnershipStoreTests.swift` (create if absent)

**Interfaces:**
- Consumes: `LostSession` (Task 2).
- Produces: `public struct SessionBaseline: Codable, Equatable { public let tokenId: String; public let sessions: [LostSession] }` (make `LostSession` `Codable`); `SessionOwnershipStore.loadBaseline() -> SessionBaseline?`, `@discardableResult saveBaseline(_ b: SessionBaseline?) -> Bool` under key `"\(keyPrefix).sessionBaseline"` (nil removes).

- [ ] **Step 1: Failing tests** `testBaselineRoundTripsPerPrefix` (two prefixes in one isolated suite don't see each other's), `testSaveNilRemoves`, `testSaveIsDiffChecked` (second identical save returns false, matching `saveNames`).
- [ ] **Step 2:** run → fail.
- [ ] **Step 3: Implement**, mirroring `saveNames`'s diff check.
- [ ] **Step 4:** run → pass.
- [ ] **Step 5: Commit** `feat(client): per-server session baseline`.

### Task 4: Swift — coordinator diff, reasons, live paths, pass signal

**Files:**
- Modify: `Sources/CodeRelayClient/ViewModels/SharedSessionCoordinator.swift` (`reconcile` ~588, `fetchSessions` ~500, `handleSessionStolen`/`cleanUpStolenSession` ~1099, local terminate/close paths, new `handleSessionEnded`)
- Modify: `Sources/CodeRelayClient/ViewModels/SessionHandshake.swift` (`Reason` gains `.enable`; delete `announceSessionsTakenElsewhere`/`firstLostSession`)
- Modify: `Sources/CodeRelayClient/RelayConnection.swift` (`onSessionEnded: ((UUID, String) -> Void)?`, dispatch next to `.sessionStolen` ~507)
- Modify: `Sources/CodeRelayClient/ViewModels/ActivityCoordinator.swift` (remove `stolenSessionName`, `stolenSessionShortId`, `showSessionStolen`, `presentStolenAlert`) and their read-throughs in `SharedSessionCoordinator` ~90-105
- Modify: `Sources/CodeRelayClient/Hub/ServerSlotCoordinating.swift` (two hooks)
- Test: `Tests/CodeRelayClientTests/SessionHandshakeTests.swift`, `Tests/CodeRelayClientTests/SharedSessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: Tasks 2–3.
- Produces:
  - `public struct SessionLossReport: Sendable { public let taken: [LostSession]; public let ended: [LostSession] }`
  - On `SharedSessionCoordinator` and in `ServerSlotCoordinating`: `var onSessionsLost: ((SessionLossReport) -> Void)? { get set }` and `func awaitPassFinished() async` (returns when no handshake, recovery, or session fetch is in flight; immediately otherwise).
  - `SessionHandshake.Reason.enable` — silent: resets the baseline from the fresh list, reports nothing.

Behaviour (the spec's §3–§4b, decided here):
- `reconcile(tokenScoped:)` is the single diff point. `before` = the stored baseline if its `tokenId` equals the current `sessionController.tokenId`, else none (token changed or first run → no report). After applying the list, compute `lost`; then **always** save the new baseline (non-terminal sessions of the list, with `name(for:)`), stamped with the current token id.
- `reconcile` returns `[LostSession]` (`@discardableResult`); the async caller (`fetchSessions` task, handshake) does: if non-empty and the reason is not `.enable` → `listAllSessions()` (`try?` → nil on failure) → `classify` → drop `ended` when `serverProtocolVersion < 4` → `onSessionsLost?` if either list non-empty. Launch and wake both report; the `.launch` silence is removed.
- Every local removal (terminate, close, `cleanUpStolenSession`, `handleSessionEnded`) removes the id from the baseline **before** any refetch.
- `handleSessionStolen` → `cleanUpStolenSession(id, refetch: true)` without an alert, then `onSessionsLost?(SessionLossReport(taken: [that], ended: []))`.
- `handleSessionEnded(id, reason)` (new, from `connection.onSessionEnded`): if listed or active, remove from pane/terminal/activity and baseline **silently**; no report.
- The hub builds slots for a just-enabled server or `rebuildSlot` with `.enable`; app launch and macOS `MainWindow` hub creation use `.launch` (Task 5 passes the reason through `start`).

- [ ] **Step 1: Failing tests** (`SharedSessionCoordinatorTests` unless noted; use the existing scripted-connection doubles):
  - `testPlainFetchThatDropsSessionsReportsAll`: baseline [A,B,C] same token; list [C]; all has A,B owned by `other` → one report taken [A,B].
  - `testListAllOnlyCalledWhenSomethingIsLost`: nothing lost → zero `session_list_all` requests.
  - `testLocallyTerminatedSessionIsNeverReported`: terminate B locally, then a fetch without B → no report.
  - `testTokenChangeDiscardsBaselineSilently`: baseline stamped `t1`, auth as `t2`, list empty → no report; baseline now stamped `t2`.
  - `testEndedSuppressedOnV3Server`: `serverProtocolVersion == 3`, lost C absent from all → no report; same with v4 → ended [C].
  - `testLiveSessionEndedRemovesSilently`: `session_ended` for listed B → B gone from `sessions` and baseline, `onSessionsLost` not called; a later fetch without B reports nothing.
  - `testLiveStealThenDiffReportsOnce`: `session_stolen` for A (reported once), then a fetch without A → no second report.
  - `SessionHandshakeTests.testLaunchReportsFromBaseline` (replaces the launch-silent test), `testEnableReasonIsSilentAndResetsBaseline`, and delete the single-session `firstLostSession` tests.
  - `testAwaitPassFinishedWaitsForInFlightHandshake`: start a handshake gated on a scripted auth; `awaitPassFinished()` returns only after it completes.
- [ ] **Step 2:** `swift test --filter 'SharedSessionCoordinatorTests|SessionHandshakeTests'` → new tests fail.
- [ ] **Step 3: Implement** per Behaviour above. Remove the stolen-alert state from `ActivityCoordinator` and the coordinator read-throughs (the app bindings are rewired in Task 6; the apps will not compile between Task 4 and Task 6 — run only the Swift gate here).
- [ ] **Step 4:** Swift gate → `EXIT=0`.
- [ ] **Step 5: Commit** `feat(client): diff every list application against a per-server baseline`.

### Task 5: Swift — hub collector and fan-out hold

**Files:**
- Create: `Sources/CodeRelayClient/Hub/SessionLossCollector.swift`
- Modify: `Sources/CodeRelayClient/Hub/ServerHub.swift` (`start()` ~117, `buildSlot` ~241, `handleForegroundTransition` ~385, `setEnabled`/`rebuildSlot` pass `.enable`)
- Modify: `Tests/CodeRelayClientTests/Hub/FakeServerSlot.swift` (the two hooks, scriptable)
- Test: `Tests/CodeRelayClientTests/Hub/SessionLossCollectorTests.swift`, `Tests/CodeRelayClientTests/Hub/ServerHubTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 4.
- Produces:
  - `@MainActor public final class SessionLossCollector { init(now: @escaping () -> Date, sleep: @escaping (Duration) async -> Void); func report(_ items: [SessionLossItem], kind: SessionLossKind); func beginHold(); func endHold(); var onFlush: ((_ taken: [SessionLossItem], _ ended: [SessionLossItem]) -> Void)? }`
  - `ServerHub`: `@Published public var takenAlert: SessionLossAlert?` with `public struct SessionLossAlert: Identifiable, Equatable { public let id: UUID; public let title: String; public let message: String }`; ended → existing `notice` set to `SessionLossCopy.endedBody`.
  - `ServerSlotCoordinating.start(reason: SessionHandshake.Reason) async` replaces `start()`.

Collector rules: dedupe by `(serverId, session.id)` within a batch; drop any item announced in the last 120 s; outside a hold, flush 1 s after the last report; `beginHold`/`endHold` nest (counter) and a flush happens at the outermost `endHold`. The hub wraps `start()` and `handleForegroundTransition` in a hold that ends when every targeted slot's trigger **and** `awaitPassFinished()` have returned, or after 10 s, whichever is first (use `BoundedWait`). Items are built with the bookmark's display name as `serverName`.

- [ ] **Step 1: Failing tests.**
  - Collector: `testTwoLiveReportsWithin1sFlushOnce`, `testRepeatWithin120sIsSuppressed` (and allowed again at 121 s), `testHoldDefersFlushUntilEndHold`, `testDuplicateInBatchCollapses`.
  - Hub: `testFanOutWaitsForPassAlreadyInFlight` (fake slot whose `handleForegroundTransition` returns at once but `awaitPassFinished` resolves later, reporting during the wait → exactly one `takenAlert` after), `testFanOutCapsAt10s` (a never-finishing slot; the other slot's report flushes at 10 s), `testStealOnNonFocusedServerSurfaces` (two slots, active on slot 1; slot 2 reports → `takenAlert` set), `testEndedGoesToNotice`, `testEnableBuildsWithEnableReason`.
- [ ] **Step 2:** `swift test --filter 'SessionLossCollectorTests|ServerHubTests'` → fail.
- [ ] **Step 3: Implement.** `buildSlot` sets `slot.onSessionsLost` to map the report into items and call `collector.report` for each non-empty kind.
- [ ] **Step 4:** Swift gate → `EXIT=0`.
- [ ] **Step 5: Commit** `feat(client): hub-level aggregated session-loss notices`.

### Task 6: iOS + macOS — one alert at the workspace root

**Files:**
- Modify: `CodeRelayApp/Views/WorkspaceView.swift` (remove the "Session Moved" alert in `FocusCoordinatorModifiers` ~226-245; add a hub-bound alert on the root view)
- Modify: `CodeRelayMac/Views/MainWindow.swift` (same, ~306-325; show `hub.notice` if the window does not already)
- Modify: any other reference to the removed `ActivityCoordinator` stolen fields (`grep -rn 'showSessionStolen\|stolenSession' CodeRelayApp CodeRelayMac`)

**Interfaces:**
- Consumes: `ServerHub.takenAlert`, `ServerHub.notice` (Task 5).

- [ ] **Step 1:** Root alert: `.alert(item: $hub.takenAlert)` (title from the item, one OK button that sets it nil). On iPhone it must not collide with the sidebar sheet or loading sheet: attach it where the existing root-level presentations live, not inside the compact `.sheet`.
- [ ] **Step 2:** iOS and Mac build gates → succeed; `grep -rn 'showSessionStolen\|stolenSessionName\|presentStolenAlert' Sources CodeRelayApp CodeRelayMac` → no matches.
- [ ] **Step 3: Visual check** with `CODERELAY_HUB_SEED=1` on the iOS simulator and the Mac app: temporarily trigger `hub.takenAlert` from the debug seed path for two sessions on two servers; screenshot shows title `Sessions Moved` and `… (on …) and … (on …) were attached from another device.` Remove the trigger before committing.
- [ ] **Step 4: Commit** `feat(apps): present session-loss alert from the hub`.

### Task 7: Kotlin — protocol v4 and `session_ended`

**Files:**
- Modify: `CodeRelayAndroid/core-protocol/src/main/kotlin/relay/protocol/ServerMessage.kt` (~75, ~138), `MessageEnvelope.kt` (~152)
- Modify: `CodeRelayAndroid/core-net/src/main/kotlin/relay/net/SessionController.kt:21` (`CURRENT = 4`)
- Modify: `CodeRelayAndroid/core-net/src/main/kotlin/relay/net/RelayConnection.kt` (`onSessionEnded`)
- Test: `CodeRelayAndroid/core-protocol/src/test/kotlin/relay/protocol/MessageEnvelopeTest.kt`

**Interfaces:**
- Produces: `ServerMessage.SessionEnded(val sessionId: UUID, val reason: String)` (`typeString "session_ended"`); `RelayConnection.onSessionEnded: ((UUID, String) -> Unit)?`.

- [ ] **Step 1: Failing test** `decodesSessionEnded` (JSON from Task 1's Swift test → `SessionEnded(id, "exited")`) and `typeStringsStayUnique`.
- [ ] **Step 2:** `./gradlew :core-protocol:test` → fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Kotlin (Android) gate → pass.
- [ ] **Step 5: Commit** `feat(kotlin): decode session_ended, protocol v4`.

### Task 8: Kotlin — classifier, copy, baseline

**Files:**
- Create: `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/hub/SessionLoss.kt`
- Modify: `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/SessionCoordinator.kt:111` (`OwnershipStore` gains baseline)
- Modify: `CodeRelayAndroid/core-storage/src/main/kotlin/relay/storage/SessionOwnershipStore.kt`, `CodeRelayLinux/linux-storage/src/main/kotlin/relay/storage/SessionOwnershipStore.kt`, adapters `CodeRelayAndroid/app/src/main/kotlin/relay/app/CoordinatorFactory.kt:32`, `CodeRelayLinux/app/src/main/kotlin/relay/app/ConnectionSession.kt:25`, and the in-memory fake in `core-session/src/test/.../CoordinatorTestDoubles.kt`
- Test: `CodeRelayAndroid/core-session/src/test/kotlin/relay/session/hub/SessionLossTest.kt`, `CodeRelayLinux/linux-storage/src/test/kotlin/relay/storage/SessionOwnershipStoreTest.kt`

**Interfaces:**
- Produces (Kotlin mirrors of Task 2–3, same semantics and copy): `data class LostSession(val id: UUID, val name: String)`, `enum class SessionLossKind { TAKEN, ENDED }`, `object SessionLossClassifier { fun lost(before: List<LostSession>, owned: List<SessionInfo>): List<LostSession>; fun classify(lost: List<LostSession>, all: List<SessionInfo>?, myTokenId: String): Pair<List<LostSession>, List<LostSession>> }`, `data class SessionLossItem(val serverId: UUID, val serverName: String, val session: LostSession)`, `object SessionLossCopy { fun takenTitle(count: Int): String; fun takenBody(items: List<SessionLossItem>): String; fun endedBody(items: List<SessionLossItem>): String }`, `data class SessionBaseline(val tokenId: String, val sessions: List<LostSession>)`; `OwnershipStore.baseline: SessionBaseline?` + `fun setBaseline(b: SessionBaseline?)`.

- [ ] **Step 1: Failing tests** — the five Task 2 tests ported 1:1 (same names in camelCase backticks, same strings) and `baselineRoundTripsAndNullRemoves` for the Linux store.
- [ ] **Step 2:** run the two gates' test tasks → fail.
- [ ] **Step 3: Implement.** Persist the baseline as JSON under the store's existing namespace (Android DataStore key / Linux file entry beside names).
- [ ] **Step 4:** both Kotlin gates → pass.
- [ ] **Step 5: Commit** `feat(kotlin): session-loss classifier, copy and baseline`.

### Task 9: Kotlin — coordinator diff, reasons, live paths, pass signal

**Files:**
- Modify: `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/SessionCoordinator.kt` (`fetchSessions` ~738, `applyServerSessions` ~797, `onSessionStolen` ~1242, `cleanUpStolenSession` ~1261, local terminate/close, new `onSessionEnded`)
- Modify: `.../SessionHandshake.kt` (`Reason.ENABLE`; delete `announceSessionsTakenElsewhere`/`firstLostSession` ~244-301)
- Modify: `.../ActivityCoordinator.kt` (remove `sessionsStolen`, `_stolenAlert`/`stolenAlert`, `sessionStolen(...)` ~108-125, ~272-292)
- Modify: `.../hub/ServerSlot.kt`, `.../hub/CoordinatorServerSlot.kt` (hooks)
- Test: `.../SessionCoordinatorTest.kt`, `.../SessionHandshakeTest.kt` (replace the single-session test ~417 and the launch-silent test ~388), `.../hub/FakeServerSlot.kt`

**Interfaces:**
- Consumes: Tasks 7–8.
- Produces: `data class SessionLossReport(val taken: List<LostSession>, val ended: List<LostSession>)`; `SessionCoordinator.onSessionsLost: ((SessionLossReport) -> Unit)?`; `suspend fun awaitPassFinished()`; on `ServerSlot`: `var onSessionsLost: ((SessionLossReport) -> Unit)?`, `suspend fun awaitPassFinished()`, `suspend fun start(reason: SessionHandshake.Reason)`.

Behaviour: identical to Task 4. `applyServerSessions` is the diff point; `RecoveryController`'s bare `fetchSessions()` tails (~321, ~327, ~470) need no change because the fetch diffs.

- [ ] **Step 1: Failing tests** — the Task 4 test list ported 1:1.
- [ ] **Step 2:** `./gradlew :core-session:testDebugUnitTest` → new tests fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Kotlin (Android) gate → pass (the `feature-workspace` alert is rewired in Task 11; if `:app:assembleDebug` fails only on the removed `stolenAlert`, defer that gate to Task 11 and say so in the commit body).
- [ ] **Step 5: Commit** `feat(kotlin): diff every list application against a per-server baseline`.

### Task 10: Kotlin — hub collector and fan-out hold

**Files:**
- Create: `CodeRelayAndroid/core-session/src/main/kotlin/relay/session/hub/SessionLossCollector.kt`
- Modify: `.../hub/ServerHub.kt` (`start` ~125, `buildSlot` ~244, `handleForegroundTransition` ~404, enable/rebuild paths)
- Modify: `CodeRelayAndroid/app/src/main/kotlin/relay/app/HubViewModel.kt:73` only if the fan-out signature changes
- Test: `.../hub/SessionLossCollectorTest.kt`, `.../hub/ServerHubTest.kt`

**Interfaces:**
- Produces: `class SessionLossCollector(scope: CoroutineScope, nowMs: () -> Long, sleepMs: suspend (Long) -> Unit)` with `report(items, kind)`, `beginHold()`, `endHold()`, `var onFlush`; `ServerHub.takenAlert: StateFlow<SessionLossAlert?>` + `fun dismissTakenAlert()`, `data class SessionLossAlert(val title: String, val message: String)`; ended → `setNotice(SessionLossCopy.endedBody(...))`.

Rules: identical to Task 5. `handleForegroundTransition()` stays non-suspending for callers; it launches one job that opens the hold, launches each slot's staggered trigger, awaits every slot's `awaitPassFinished()` under `withTimeoutOrNull(10_000)`, then closes the hold.

- [ ] **Step 1: Failing tests** — the Task 5 test list ported 1:1, driven by `TestScope` virtual time.
- [ ] **Step 2:** run → fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** `:core-session:testDebugUnitTest` → pass.
- [ ] **Step 5: Commit** `feat(kotlin): hub-level aggregated session-loss notices`.

### Task 11: Android + Linux — one dialog at the workspace root

**Files:**
- Modify: `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/WorkspaceScreen.kt` (remove the per-pane "Session Moved" `AlertDialog` ~544-556)
- Modify: `CodeRelayAndroid/feature-workspace/src/main/kotlin/relay/feature/workspace/HubWorkspaceScreen.kt` (collect `hub.takenAlert`; one `AlertDialog` above the per-server pane; OK → `hub.dismissTakenAlert()`; confirm `hub.notice` is rendered)

**Interfaces:**
- Consumes: Task 10.

- [ ] **Step 1:** Implement; `grep -rn 'stolenAlert\|sessionsStolen' CodeRelayAndroid CodeRelayLinux --include='*.kt'` → no matches outside build dirs.
- [ ] **Step 2:** Both Kotlin gates → pass (this compiles `feature-workspace` for Android and Linux).
- [ ] **Step 3: Visual check** with Compose `@Preview`s of the dialog (1 session; 2 sessions on two servers; 4 sessions) rendered via the existing preview/screenshot tooling — no live relay is touched. Screenshots show the exact Global Constraints copy.
- [ ] **Step 4: Commit** `feat(android,linux): present session-loss dialog from the hub`.

### Task 12: Docs

**Files:**
- Modify: `CLAUDE.md` (Wire Protocol: v4 + `session_ended`; App Architecture: hub-level `SessionLossCollector`, baseline is diff-only)
- Modify: `Sources/CodeRelayClient/CLAUDE.md` (ServerHub section: collector + `awaitPassFinished`)
- Modify: `CHANGELOG.md` (Unreleased: user-facing behaviour in one paragraph)

- [ ] **Step 1:** Write the entries; no other files.
- [ ] **Step 2:** Swift gate → `EXIT=0` (sanity).
- [ ] **Step 3: Commit** `docs: session takeover notices`.
