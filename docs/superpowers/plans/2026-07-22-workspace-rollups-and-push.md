# Workspace Rollups & Push Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Revision 3** — incorporates two rounds of adversarial Codex review (2026-07-22). Rev 2 fixed file paths/signatures, per-device prefs, TTL/caps, crypto/HTTP hardening. Rev 3 fixes two correctness blockers Codex round 2 found: (1) the dispatcher now forwards event state through an ORDERED stream so a fast `working→blocked→idle` burst can't lose the blocked edge, and (2) edge detection is PER-SESSION so one session finishing fires even when a sibling stays working. See "Design decisions (locked)" #7 and Tasks 14/15.

**Goal:** Group sessions by repository/working directory with a rolled-up worst-state badge (F2), then push an OS notification to the owning devices when an agent in a group becomes `blocked` or finishes (F1) — coalesced to one actionable alert per project.

**Architecture:** Built server-outward in two phases. **F2:** capture each PTY's cwd (actor-safe, refreshed on the foreground poll), resolve it to a git root, put it on `SessionInfo`; a pure `WorkspaceRollup` value type (in `ClaudeRelayKit`) folds a session list into groups; clients render grouped sidebars driven by live `ActivityCoordinator` state. **F1:** devices register APNs/FCM tokens *with per-device notification preferences* over new wire messages; a capped, TTL-reaped `PushRegistrationStore` persists them; a `PushDispatcher` actor observes the server's activity stream via a new **global** observer, tracks the **prior** per-(token, group) rollup state to detect real transition edges, debounces, and fans out via APNs (ES256 JWT/HTTP2) and FCM v1 (service-account OAuth) through a bounded, retrying HTTP path.

**Tech Stack:** Swift 6 (server/kit/clients), SwiftNIO, `swift-crypto` (`Crypto` for ES256, `_CryptoExtras` for RSA — both added explicitly to the server target), `AsyncHTTPClient` (NEW server dep — HTTP/2), SwiftUI (iOS/macOS), Jetpack Compose + Firebase Messaging (Android), XCTest (server/kit), JUnit5 (Android).

## Global Constraints

- **Wire protocol:** every WebSocket message goes through `MessageEnvelope` — an `enum` with cases `.client(ClientMessage)` / `.server(ServerMessage)`. New type strings MUST be unique across BOTH `ClientMessage.allTypeStrings` and `ServerMessage.allTypeStrings`. `ClientMessage`/`ServerMessage` decode only via `MessageEnvelope`.
- **Protocol versioning:** `minProtocolVersion` stays `0`. Every new field/message MUST be additive and optional. An older client (never sends a push token) and an older server (never sends `workingDir`) must both keep working.
- **Codable back-compat:** `SessionInfo` uses **synthesized** Codable — a new optional property decodes to `nil` when the key is absent, automatically. `RelayConfig` uses a **custom** `init(from:)` + `CodingKeys` (RelayConfig.swift:88-108) — new keys MUST be added to BOTH the `CodingKeys` enum and the decoder body with `decodeIfPresent(...) ?? default`.
- **Date encoding:** WebSocket path uses default `JSONEncoder` (Double timestamps); Admin HTTP uses `.iso8601`. Never mix.
- **Concurrency:** `SessionManager` and `PTYSession` are `actor`s; `PTYSessionProtocol` is `: Actor` (PTYSession.swift:7) — any method on it is actor-isolated and MUST be `await`ed from outside. `SessionActivityMonitor` is `final class @unchecked Sendable` inside the `PTYSession` isolation domain. `ActivityCoordinator` is `@MainActor ObservableObject`. All observer closures are `@Sendable`.
- **Memory bounds (named caps, per CLAUDE.md):** every new map MUST have an explicit cap + reap policy: `PushRegistrationStore` (per-token cap AND a global record cap, TTL reap), `PushDispatcher` prior-state + debounce maps (cap + age reap). Bound all untrusted input sizes (token ≤ 512 chars, deviceId ≤ 128 chars).
- **Secrets:** APNs `.p8`, key/team/bundle id, FCM service-account JSON are server config, never logged. Redact any `bearer`/token substring in error logs (follow `CloudPromptEnhancer`). Device push tokens are secrets: persist with `0o600` file perms.
- **Server management:** never run the binary directly or `pkill`; use `swift run claude-relay restart|health`. Tests use `swift test`.
- **Lint:** SwiftLint warns at 140 cols, errors at 200. Identifier min length 2.
- **Versioning:** do NOT bump app/server versions in this plan; shipping is a separate step.

## Design decisions (locked — resolve Codex's open questions)

1. **Rollup data source is live, not snapshots.** Clients compute rollups from `ActivityCoordinator.agentStates` / `agentSessions` (populated by activity observer events, which lead session-list snapshots), joined to the session list only for identity/`workingDir`. Server-side, the `PushDispatcher` computes rollups from `SessionManager.listSessionsForToken` snapshots BUT tracks its own prior-rollup map so a lagging snapshot cannot fabricate a false edge (Task 14).
2. **"Finished" is a server edge, "unseen" is client-only.** The server does NOT know a client's "seen" bit. So: the client `RollupState.finishedUnseen` is a *display* state derived from the client's `unseenSessions`. The server's push trigger fires on the **`working → idle` activity edge** (agent finished), gated by the device's `notifyOnFinished` preference. This makes finished pushes actually deliverable (the v1 draft's `unseenProvider: {[]}` made them impossible).
3. **Notification prefs are per-device.** `registerPushToken` carries `enabled: Bool` and `notifyOnFinished: Bool`; `PushRegistrationStore` stores them per record; the dispatcher reads per-record prefs. A global config key cannot express different choices across a user's phone vs. Mac.
4. **cwd capture is actor-safe and poll-driven.** cwd is read inside the `PTYSession` actor during the existing foreground-process poll (not on activity transitions — a plain `cd` emits no activity event). `PTYSessionProtocol` gains `func currentWorkingDirectory() async -> String?`; `MockPTYSession` implements it. Grouping key is the **git root** of the cwd (bounded, cached lookup), falling back to the cwd itself, then `"~"`.
5. **Push collapse key is a hashed, privacy-safe id.** The dispatcher never sends a raw host path to APNs/FCM. `collapseKey = "ws_" + SHA256(groupId).prefix(16)`; notification copy uses only the sanitized group *display name* (leaf dir / repo name).
6. **One push result type:** `enum PushResult { case delivered; case unregistered; case failed(String) }`, shared by both clients (`APNsClient`, `FCMClient`) and the `PushSending` protocol.
7. **Edge detection is per-session and order-preserving (Rev 3 — Codex round 2).** The activity observer forwards the **actual event state** (`agentState`, `activity`, `revision`) — never just an id to be re-looked-up — into an **ordered** dispatcher queue (a single `AsyncStream` drained by one consumer task), so a fast `working→blocked→idle` sequence cannot collapse to only the final snapshot and lose the blocked edge. The dispatcher tracks prior state **per session** (`previousSessionState: [UUID: AgentDetectedState]`), detects the edge on that session (`working→blocked`, `working→idle`), and only THEN coalesces the resulting notification by group. Group rollup is used for the notification *body/count/deep-link*, never as the edge source — because one session finishing while a sibling stays `working` leaves the group aggregate at `.working` and would hide the finish edge.

---

## File Structure

**New files:**
- `Sources/ClaudeRelayKit/Models/WorkspaceRollup.swift` — pure grouping/rollup value types + fold. No I/O.
- `Sources/ClaudeRelayKit/Models/PushRegistration.swift` — `PushPlatform` enum + `PushRegistration` (wire + storage model, incl. prefs + timestamps).
- `Sources/ClaudeRelayServer/Push/GitRootResolver.swift` — bounded, cached cwd→git-root resolver.
- `Sources/ClaudeRelayServer/Push/PushRegistrationStore.swift` — actor: per-token + global caps, TTL reap, atomic 0o600 persistence.
- `Sources/ClaudeRelayServer/Push/PushSending.swift` — `PushResult` + `PushSending` protocol + `CompositePushSender`.
- `Sources/ClaudeRelayServer/Push/APNsClient.swift` — ES256 JWT + bounded/retrying HTTP/2 POST.
- `Sources/ClaudeRelayServer/Push/FCMClient.swift` — service-account RS256 JWT → OAuth → v1 send.
- `Sources/ClaudeRelayServer/Push/PushDispatcher.swift` — global observer, prior-state edge detection, debounce, fan-out.
- `Sources/ClaudeRelayServer/Push/PushHTTP.swift` — small `AsyncHTTPClient` wrapper: capped body read, timeouts, 429/5xx retry w/ backoff, auth redaction.
- Tests: `WorkspaceRollupTests`, `PushRegistrationTests`, `GitRootResolverTests`, `PushRegistrationStoreTests`, `APNsClientTests`, `FCMClientTests`, `PushDispatcherTests`, plus mock-HTTP integration tests `APNsIntegrationTests`, `FCMIntegrationTests`.

**Modified files:** `Sources/CPTYShim/include/pty_shim.h` + `Sources/CPTYShim/pty_shim.c` (add `relay_proc_cwd`); `PTYSession.swift` (+`PTYSessionProtocol`); `SessionInfo.swift`; `SessionManager.swift`; `ClientMessage.swift`; `ServerMessage.swift`; `RelayMessageHandler.swift` (+ its injected deps in `WebSocketServer.swift`); `main.swift`; `RelayConfig.swift` + `AdminRoutes.swift` + CLI `ConfigSetCommand`; `ActivityCoordinator.swift`; iOS/macOS `SessionSidebarView.swift`; iOS/macOS app entry + `AppSettings.swift` + `SettingsView.swift`; `project.yml` (entitlements); `Package.swift`; Android `ActivityCoordinator.kt`, `SessionSidebar.kt`, `SessionInfo.kt`, new FCM service, `WorkspaceRollup.kt`, settings, Gradle.

---

# Phase 1 — F2: Workspace Status Rollups

## Task 1: `WorkspaceRollup` pure value type + fold (Kit)

**Files:** Create `Sources/ClaudeRelayKit/Models/WorkspaceRollup.swift`; Test `Tests/ClaudeRelayKitTests/WorkspaceRollupTests.swift`. **Do Task 6 (adds `SessionInfo.workingDir`) FIRST** — this task's test won't compile without it.

**Interfaces:**
- Consumes: `SessionInfo` (with `workingDir` from Task 6), `AgentDetectedState` (`.idle`/`.working`/`.blocked`/`.unknown`).
- Produces:
  - `enum RollupState: Int, Comparable, Sendable { case seen = 0, unknown = 1, working = 2, finishedUnseen = 3, blocked = 4 }`
  - `struct WorkspaceRollup: Equatable, Sendable, Identifiable { let id: String; let title: String; let sessionIds: [UUID]; let state: RollupState; let attentionCount: Int }`
  - `static func rollupState(for: SessionInfo, unseen: Set<UUID>) -> RollupState`
  - `static func group(sessions: [SessionInfo], agentStates: [UUID: AgentDetectedState], unseen: Set<UUID>, groupKey: (SessionInfo) -> String, title: (String) -> String) -> [WorkspaceRollup]` — **takes a live `agentStates` map** (design decision 1); a session's effective state is `agentStates[id] ?? session.agentState`, so an observer event that has arrived ahead of the session-list snapshot wins.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeRelayKit

final class WorkspaceRollupTests: XCTestCase {
    private func session(_ agent: String?, _ state: AgentDetectedState?, dir: String, id: UUID = UUID()) -> SessionInfo {
        SessionInfo(id: id, name: nil, state: .active, tokenId: "t", createdAt: Date(),
                    cols: 80, rows: 24, activity: .agentActive, agent: agent,
                    agentState: state, title: nil, workingDir: dir)
    }

    func testRollupStateBlockedIsHighest() {
        XCTAssertEqual(WorkspaceRollup.rollupState(for: session("claude", .blocked, dir: "/r"), unseen: []), .blocked)
    }
    func testFinishedUnseenVsSeen() {
        let s = session("claude", .idle, dir: "/r")
        XCTAssertEqual(WorkspaceRollup.rollupState(for: s, unseen: [s.id]), .finishedUnseen)
        XCTAssertEqual(WorkspaceRollup.rollupState(for: s, unseen: []), .seen)
    }
    func testGroupPicksWorstAndSortsBySeverity() {
        let a = session("claude", .working, dir: "/repo/a")
        let b = session("claude", .blocked, dir: "/repo/a")
        let c = session("codex", .idle, dir: "/repo/b")
        let groups = WorkspaceRollup.group(sessions: [a, b, c], agentStates: [:], unseen: [],
            groupKey: { $0.workingDir ?? "~" }, title: { ($0 as NSString).lastPathComponent })
        XCTAssertEqual(groups.first?.id, "/repo/a")
        XCTAssertEqual(groups.first?.state, .blocked)
        XCTAssertEqual(groups.first?.attentionCount, 1)
        XCTAssertEqual(groups.count, 2)
    }
    func testLiveAgentStatesOverrideStaleSnapshot() {
        // Snapshot says working; a fresher observer event says blocked → blocked wins.
        let s = session("claude", .working, dir: "/repo/a")
        let groups = WorkspaceRollup.group(sessions: [s], agentStates: [s.id: .blocked], unseen: [],
            groupKey: { $0.workingDir ?? "~" }, title: { $0 })
        XCTAssertEqual(groups.first?.state, .blocked)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter WorkspaceRollupTests` → FAIL (undefined).

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum RollupState: Int, Comparable, Sendable {
    case seen = 0, unknown = 1, working = 2, finishedUnseen = 3, blocked = 4
    public static func < (l: RollupState, r: RollupState) -> Bool { l.rawValue < r.rawValue }
}

public struct WorkspaceRollup: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let sessionIds: [UUID]
    public let state: RollupState
    public let attentionCount: Int
    public init(id: String, title: String, sessionIds: [UUID], state: RollupState, attentionCount: Int) {
        self.id = id; self.title = title; self.sessionIds = sessionIds
        self.state = state; self.attentionCount = attentionCount
    }

    public static func rollupState(for s: SessionInfo, unseen: Set<UUID>,
                                   liveState: AgentDetectedState? = nil) -> RollupState {
        guard s.agent != nil else { return .seen }
        switch liveState ?? s.agentState {
        case .blocked: return .blocked
        case .idle:    return unseen.contains(s.id) ? .finishedUnseen : .seen
        case .working: return .working
        case .unknown, .none: return .unknown
        }
    }

    public static func group(
        sessions: [SessionInfo], agentStates: [UUID: AgentDetectedState], unseen: Set<UUID>,
        groupKey: (SessionInfo) -> String, title: (String) -> String
    ) -> [WorkspaceRollup] {
        var buckets: [String: [SessionInfo]] = [:]
        for s in sessions { buckets[groupKey(s), default: []].append(s) }
        return buckets.map { key, members -> WorkspaceRollup in
            let states = members.map { rollupState(for: $0, unseen: unseen, liveState: agentStates[$0.id]) }
            return WorkspaceRollup(
                id: key, title: title(key), sessionIds: members.map(\.id),
                state: states.max() ?? .seen,
                attentionCount: states.filter { $0 == .blocked || $0 == .finishedUnseen }.count)
        }.sorted { $0.state != $1.state ? $0.state > $1.state : $0.title < $1.title }
    }
}
```

- [ ] **Step 4: Run to verify it passes** — `swift test --filter WorkspaceRollupTests` → PASS (4 tests).
- [ ] **Step 5: Commit** — `git add … && git commit -m "feat(kit): add WorkspaceRollup pure grouping value type (live-state aware)"`

---

## Task 6: add `workingDir` to `SessionInfo` (execute BEFORE Task 1)

**Files:** Modify `Sources/ClaudeRelayKit/Models/SessionInfo.swift`; Test `Tests/ClaudeRelayKitTests/SessionInfoTests.swift`.

**Interfaces:** `SessionInfo.workingDir: String?` (synthesized-Codable optional → absent key decodes `nil`), threaded through `transitioning`, `with(name:)`, `with(tokenId:)`, `enriched`.

- [ ] **Step 1: Failing test** (append)

```swift
func testWorkingDirRoundTrips() throws {
    let info = SessionInfo(id: UUID(), state: .active, tokenId: "t", createdAt: Date(timeIntervalSince1970: 1),
                           cols: 80, rows: 24, workingDir: "/repo/x")
    let back = try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(info))
    XCTAssertEqual(back.workingDir, "/repo/x")
}
func testWorkingDirAbsentDecodesNil() throws {
    let json = #"{"id":"\#(UUID().uuidString)","state":"active","tokenId":"t","createdAt":1,"cols":80,"rows":24}"#
    XCTAssertNil(try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8)).workingDir)
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter SessionInfoTests` → FAIL (no `workingDir:`).
- [ ] **Step 3: Implement** — add stored `public let workingDir: String?` after `title`; add `workingDir: String? = nil` as the LAST `init` param; assign it; add `workingDir: workingDir` to every copy-helper `SessionInfo(...)` call; extend `enriched` with `workingDir: String? = nil` and pass `workingDir ?? self.workingDir`.
- [ ] **Step 4: Run to verify it passes** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): add optional workingDir to SessionInfo"`

---

## Task 7: cwd capture on `PTYSession` + protocol (actor-safe)

**Files:** Modify `Sources/CPTYShim/include/pty_shim.h`, `Sources/CPTYShim/pty_shim.c`, `Sources/ClaudeRelayServer/Actors/PTYSession.swift` (incl. `PTYSessionProtocol` at line 7); Test `Tests/ClaudeRelayServerTests/PTYSessionCwdTests.swift`.

**Interfaces:**
- Add to `protocol PTYSessionProtocol: Actor` a requirement `func currentWorkingDirectory() async -> String?`.
- `PTYSession.currentWorkingDirectory()` reads the **shell child pid's** cwd (design decision 4: the persistent shell, not a transient foreground subprocess — the shell is the stable workspace anchor). Actor-isolated; callers `await`.
- C shim: `int relay_proc_cwd(pid_t pid, char *buf, int buflen)`.

- [ ] **Step 1: Failing test** (note the `await`s and the real init signature)

```swift
import XCTest
@testable import ClaudeRelayServer

final class PTYSessionCwdTests: XCTestCase {
    func testCurrentWorkingDirectoryTracksCd() async throws {
        let session = try PTYSession(sessionId: UUID(), cols: 80, rows: 24, scrollbackSize: 4096)
        await session.startReading()
        defer { Task { await session.terminate() } }
        await session.write("cd /tmp\n".data(using: .utf8)!)
        try await Task.sleep(for: .milliseconds(800))
        let cwd = await session.currentWorkingDirectory()
        XCTAssertTrue(cwd == "/tmp" || cwd == "/private/tmp", "got \(String(describing: cwd))")
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter PTYSessionCwdTests` → FAIL (undefined).
- [ ] **Step 3a: C shim** — in `Sources/CPTYShim/include/pty_shim.h`:

```c
#include <sys/types.h>
int relay_proc_cwd(pid_t pid, char *buf, int buflen);
```
in `Sources/CPTYShim/pty_shim.c`:
```c
#include <libproc.h>
#include <string.h>
int relay_proc_cwd(pid_t pid, char *buf, int buflen) {
    struct proc_vnodepathinfo vpi;
    int ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
    if (ret <= 0) return -1;
    size_t len = strlen(vpi.pvi_cdir.vip_path);
    if ((int)len + 1 > buflen) return -1;
    memcpy(buf, vpi.pvi_cdir.vip_path, len + 1);
    return 0;
}
```

- [ ] **Step 3b: Swift** — add the protocol requirement to `PTYSessionProtocol` (PTYSession.swift:7), and implement on `PTYSession` (reads the actor's stored `childPID`):

```swift
    /// Best-effort cwd of the session's shell (the stable workspace anchor).
    /// Actor-isolated — callers await. Nil if the process is gone.
    public func currentWorkingDirectory() -> String? {
        var buf = [CChar](repeating: 0, count: 1024)
        guard relay_proc_cwd(childPID, &buf, Int32(buf.count)) == 0 else { return nil }
        return String(cString: buf)
    }
```
(`String` return on an `async` protocol requirement is fine — an actor method satisfies `func … async`. The shim module is already imported for `relay_forkpty`.)

- [ ] **Step 3c: MockPTYSession** — add `func currentWorkingDirectory() -> String? { mockCwd }` with a settable `var mockCwd: String?` to `MockPTYSession` in `Tests/ClaudeRelayServerTests/SessionManagerTestCase.swift`.
- [ ] **Step 4: Run to verify it passes** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(server): actor-safe PTY cwd capture via proc_pidinfo shim"`

---

## Task 7b: `GitRootResolver` (bounded, cached)

**Files:** Create `Sources/ClaudeRelayServer/Push/GitRootResolver.swift`; Test `Tests/ClaudeRelayServerTests/GitRootResolverTests.swift`.

**Interfaces:** `actor GitRootResolver { func root(for path: String) async -> String }` — walks up from `path` looking for a `.git` dir (no subprocess; `FileManager` checks), normalizes symlinks via `URL.resolvingSymlinksInPath()`, returns the git root or the input path if none. LRU-caches results (cap 256) so repeated polls don't re-walk. Returns `"~"` for empty/home.

- [ ] **Step 1: Failing test**

```swift
func testRootFindsGitDirAncestor() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sub = tmp.appendingPathComponent("Sources/Deep")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tmp.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let resolver = GitRootResolver()
    let root = await resolver.root(for: sub.path)
    XCTAssertEqual(URL(fileURLWithPath: root).resolvingSymlinksInPath().path,
                   tmp.resolvingSymlinksInPath().path)
}
func testRootFallsBackToInputWhenNoGit() async {
    let root = await GitRootResolver().root(for: "/private/tmp")
    XCTAssertEqual(root, "/private/tmp")
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement** the actor (ancestor walk + symlink normalize + LRU cap 256).
- [ ] **Step 4: Run to verify it passes** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(server): add cached GitRootResolver for workspace grouping"`

---

## Task 8: thread cwd→git-root into SessionManager (poll-driven)

**Files:** Modify `Sources/ClaudeRelayServer/Actors/SessionManager.swift`, and the PTY foreground poll wiring; Test extend `Tests/ClaudeRelayServerTests/SessionManagerTestCase.swift` or new `SessionManagerWorkingDirTests.swift`.

**Interfaces:**
- `ManagedSession` gains `var latestWorkingDir: String?`.
- cwd is refreshed **on the foreground poll** (design decision 4), NOT on activity transitions. The poll already runs inside `PTYSession`; extend it to call `currentWorkingDirectory()`, resolve to git root via an injected `GitRootResolver`, and if changed from the cached value, notify `SessionManager` via a new lightweight path `reportWorkingDir(sessionId:workingDir:)`.
- `listSessionsForToken` / `listAllSessions` pass `workingDir: $0.latestWorkingDir` into `.enriched(...)`.

- [ ] **Step 1: Failing test**

```swift
func testWorkingDirSurfacesInListing() async throws {
    let manager = makeManager()   // existing harness factory (MockPTYSession)
    let info = try await manager.createSession(tokenId: "tok")
    await manager.reportWorkingDir(sessionId: info.id, workingDir: "/repo/demo")
    let listed = await manager.listSessionsForToken(tokenId: "tok")
    XCTAssertEqual(listed.first?.workingDir, "/repo/demo")
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL (`reportWorkingDir` undefined).
- [ ] **Step 3: Implement.**
  1. Add `var latestWorkingDir: String?` to `ManagedSession`.
  2. Add `public func reportWorkingDir(sessionId: UUID, workingDir: String)` to `SessionManager`: guard the session exists, set `managed.latestWorkingDir = workingDir`, and fire the activity observers with the CURRENT cached activity so clients get a refreshed `SessionInfo` (reuse the existing `activityObservers.forToken` fan-out; pass current `latestActivity/latestAgent/latestAgentState/latestTitle`). This is why grouping updates on `cd` even without an activity change.
  3. In `createSession`, after building the PTY, install the git-root-resolving poll hook. The poll lives in `PTYSession`; add a setter `setWorkingDirHandler { [weak self] cwd in Task { await self?.handleCwd(sessionId, cwd) } }` where `handleCwd` resolves git root (via the manager's injected `GitRootResolver`) and calls `reportWorkingDir` only when the resolved root changed.
  4. Pass `workingDir: $0.latestWorkingDir` into both enriched listings (`listSessionsForToken`, `listAllSessions`).
  5. Inject `GitRootResolver` into `SessionManager.init` (default `GitRootResolver()`), wired from `main.swift`.
- [ ] **Step 4: Run to verify it passes** — `swift test --filter SessionManager` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(server): track cwd→git-root per session, refreshed on foreground poll"`

---

## Task 9: `rollups(for:)` on ActivityCoordinator (live state)

**Files:** Modify `Sources/ClaudeRelayClient/ViewModels/ActivityCoordinator.swift`; Test `Tests/ClaudeRelayClientTests/ActivityCoordinatorRollupTests.swift`.

**Interfaces:** `func rollups(for sessions: [SessionInfo]) -> [WorkspaceRollup]` — passes `agentStates` (existing `@Published [UUID: AgentDetectedState]`, line 38) and `unseenSessions` (line 46) into `WorkspaceRollup.group`, so rollups reflect the freshest observer data (design decision 1). Group key delegates git-root grouping to the server-provided `workingDir` (already a git root from Task 8).

- [ ] **Step 1: Failing test**

```swift
@MainActor
final class ActivityCoordinatorRollupTests: XCTestCase {
    func testRollupsUseLiveAgentStates() {
        let coord = ActivityCoordinator(ownershipStore: SessionOwnershipStore(store: InMemoryKeyValueStore()),
                                        initialAgents: [:])
        let s = SessionInfo(id: UUID(), state: .active, tokenId: "t", createdAt: Date(),
                            cols: 80, rows: 24, activity: .agentActive, agent: "claude",
                            agentState: .working, workingDir: "/repo/a")
        coord.agentStates[s.id] = .blocked          // live event ahead of snapshot
        XCTAssertEqual(coord.rollups(for: [s]).first?.state, .blocked)
    }
}
```
> Match the real `SessionOwnershipStore` test initializer — grep `Tests/ClaudeRelayClientTests` for how existing tests construct it; use that exact idiom.

- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement**

```swift
    public func rollups(for sessions: [SessionInfo]) -> [WorkspaceRollup] {
        WorkspaceRollup.group(
            sessions: sessions, agentStates: agentStates, unseen: unseenSessions,
            groupKey: { $0.workingDir ?? "~" },
            title: { $0 == "~" ? "Other" : ($0 as NSString).lastPathComponent })
    }
```

- [ ] **Step 4: Run to verify it passes** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(client): workspace rollups from live ActivityCoordinator state"`

---

## Task 10: grouped, collapsible sidebar (iOS + macOS)

**Files:** Modify `ClaudeRelayApp/Views/SessionSidebarView.swift`, `ClaudeRelayMac/Views/SessionSidebarView.swift`; Test: a small view-model-level test for collapse state (`Tests/ClaudeRelayClientTests/SidebarCollapseTests.swift`) since the collapse set is testable logic; the SwiftUI layout itself is verified by running.

**Interfaces:** Consumes `coordinator.activityCoordinator.rollups(for:)`. Collapse state is a real `@State private var collapsedGroups: Set<String>` (design decision: Codex flagged the v1 "collapsible" claim was non-functional). A tiny helper `SidebarCollapseModel` holds the set + `toggle(_:)` + `isCollapsed(_:)` so it's unit-testable; the view binds to it.

- [ ] **Step 1: Failing test** (collapse logic)

```swift
final class SidebarCollapseTests: XCTestCase {
    func testToggleCollapsesAndExpands() {
        var m = SidebarCollapseModel()
        XCTAssertFalse(m.isCollapsed("/repo/a"))
        m.toggle("/repo/a"); XCTAssertTrue(m.isCollapsed("/repo/a"))
        m.toggle("/repo/a"); XCTAssertFalse(m.isCollapsed("/repo/a"))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement** `SidebarCollapseModel` (in ClaudeRelayClient, shared by both apps):

```swift
public struct SidebarCollapseModel: Equatable {
    private var collapsed: Set<String> = []
    public init() {}
    public func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }
    public mutating func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}
```

- [ ] **Step 4: Run to verify it passes** — PASS.
- [ ] **Step 5: Implement the SwiftUI sidebar (iOS)** — group rows by rollup, header row is a `Button` toggling `collapsedGroups`, showing a disclosure chevron, a `RollupBadge(state:)` dot, `title`, and a red count chip when `attentionCount > 0`. Hide member rows when `collapsedGroups.contains(group.id)`. `RollupBadge` maps `RollupState`→color (`.blocked→.red`, `.finishedUnseen→.yellow`, `.working→.teal`, `.unknown→.gray`, `.seen→.green`); use `Color.contrastingLabel` for chip text.
- [ ] **Step 6: Verify (iOS)** — run app, two sessions in different git repos, confirm grouping, worst-first sort, chevron collapse, red badge on blocked group.
- [ ] **Step 7: Implement + verify (macOS)** — mirror in `ClaudeRelayMac`.
- [ ] **Step 8: Commit** — `git commit -m "feat(ios,mac): collapsible grouped workspace sidebar"`

---

## Task 11: Android rollup + grouped sidebar

**Files:** Create `ClaudeRelayAndroid/core-protocol/.../WorkspaceRollup.kt`; modify `SessionInfo.kt` (add `workingDir: String?`), `ActivityCoordinator.kt` (`rollups(...)` using `agentStates.value`), `SessionSidebar.kt` (grouped, collapsible via remembered `Set<String>`); Test `WorkspaceRollupTest.kt`.

**Interfaces:** mirror Swift exactly — `RollupState` ordinal = severity, `group(...)` takes `agentStates: Map<UUID, AgentDetectedState>`, same worst-wins + sort.

- [ ] **Step 1: Failing Kotlin test** (group by dir, worst wins, live-state override) — mirror Task 1's four cases.
- [ ] **Step 2: Run to verify it fails** — `cd ClaudeRelayAndroid && ./gradlew :core-protocol:testDebugUnitTest --tests "*.WorkspaceRollupTest"` → FAIL.
- [ ] **Step 3: Implement** `SessionInfo.workingDir: String? = null`, `WorkspaceRollup` (companion `rollupState`/`group` matching Swift), `ActivityCoordinator.rollups(sessions)` using `agentStates.value` + `unseenSessions.value`.
- [ ] **Step 4: Run to verify it passes** — PASS.
- [ ] **Step 5: Grouped collapsible Compose sidebar** — `stickyHeader` per rollup, remembered collapsed set, badge + count chip. Build `./gradlew :app:assembleDebug`.
- [ ] **Step 6: Commit** — `git commit -m "feat(android): workspace rollups + collapsible grouped sidebar"`

---

# Phase 2 — F1: Push Notifications

## Task 2: `PushRegistration` model + wire messages (Kit)

**Files:** Create `Sources/ClaudeRelayKit/Models/PushRegistration.swift`; modify `ClientMessage.swift`, `ServerMessage.swift`; Test `Tests/ClaudeRelayKitTests/PushRegistrationTests.swift`, `PushMessageTests.swift`.

**Interfaces:**
- `enum PushPlatform: String, Codable, Sendable { case apns, fcm }`
- `struct PushRegistration: Codable, Equatable, Sendable { let platform: PushPlatform; let token: String; let deviceId: String; var enabled: Bool; var notifyOnFinished: Bool; var updatedAt: Date }` (prefs + timestamp per design decisions 3 & the TTL requirement).
- `ClientMessage.registerPushToken(platform:token:deviceId:enabled:notifyOnFinished:)` → `"register_push_token"`
- `ClientMessage.unregisterPushToken(deviceId:)` → `"unregister_push_token"`
- `ServerMessage.pushTokenAck(accepted: Bool)` → `"push_token_ack"`
- **Validation (design/security):** `PushRegistration.isValid` — non-empty token ≤ 512 chars, deviceId ≤ 128 chars; the handler (Task 4) rejects invalid input.

- [ ] **Step 1: Failing test** — envelope round-trips using the verified enum idiom:

```swift
func testRegisterRoundTrips() throws {
    let msg = ClientMessage.registerPushToken(platform: .apns, token: "abc", deviceId: "d1",
                                              enabled: true, notifyOnFinished: false)
    let data = try JSONEncoder().encode(MessageEnvelope.client(msg))
    guard case .client(.registerPushToken(let p, let t, let d, let en, let nf)) =
            try JSONDecoder().decode(MessageEnvelope.self, from: data) else { return XCTFail() }
    XCTAssertEqual([p == .apns, t == "abc", d == "d1", en, !nf], [true, true, true, true, true])
}
func testAckRoundTrips() throws {
    let data = try JSONEncoder().encode(MessageEnvelope.server(.pushTokenAck(accepted: true)))
    guard case .server(.pushTokenAck(true)) = try JSONDecoder().decode(MessageEnvelope.self, from: data) else { return XCTFail() }
}
func testValidationRejectsOversizeToken() {
    let r = PushRegistration(platform: .apns, token: String(repeating: "x", count: 513),
                             deviceId: "d", enabled: true, notifyOnFinished: false, updatedAt: Date())
    XCTAssertFalse(r.isValid)
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement** — the model + `isValid`; add the two client cases (typeStrings + `allTypeStrings` + `PayloadCodingKeys` gains `platform, deviceId, enabled, notifyOnFinished` — reuse existing `token`; add encode/decode arms), and the server case (`accepted` key). Use `decodeIfPresent(...) ?? default` for `enabled`/`notifyOnFinished` so a future field addition stays back-compatible.
- [ ] **Step 4: Run to verify it passes** — `swift test --filter PushMessageTests && swift test --filter ServerMessageTests` → PASS (collision guard still green).
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): push registration model + wire messages with prefs"`

---

## Task 3: `PushRegistrationStore` (caps, TTL, atomic 0o600)

**Files:** Create `Sources/ClaudeRelayServer/Push/PushRegistrationStore.swift`; Test `Tests/ClaudeRelayServerTests/PushRegistrationStoreTests.swift`.

**Interfaces (actor):**
- `init(directory: URL, maxPerToken: Int = 20, maxTotal: Int = 5000, ttl: TimeInterval = 90*24*3600, now: @escaping @Sendable () -> Date = Date.init)` (injected clock for deterministic TTL tests).
- `func upsert(_ reg: PushRegistration, forTokenId: String)` — replace by `deviceId`; evict oldest-by-`updatedAt` over `maxPerToken`; globally reject/evict over `maxTotal`.
- `func setPreferences(deviceId: String, forTokenId: String, enabled: Bool, notifyOnFinished: Bool)` — update prefs without a new token (used when the user flips the setting).
- `func remove(deviceId: String, forTokenId: String)`
- `func removeToken(_ token: String)` — dead-token feedback purge across all relay-tokens.
- `func registrations(forTokenId: String) -> [PushRegistration]` — filters out entries older than `ttl`.
- `func reap()` — drops expired; called on a timer from `main.swift`.
- Atomic persistence: write to temp then `rename`, `chmod 0o600`; dirty-flush like `TokenStore`.

- [ ] **Step 1: Failing test** — upsert/fetch scoping, re-register replaces, per-token cap eviction, global cap, `removeToken` everywhere, and TTL reap with injected clock:

```swift
func testTTLReapDropsExpired() async {
    var t = Date(timeIntervalSince1970: 0)
    let store = PushRegistrationStore(directory: tmp(), ttl: 100, now: { t })
    await store.upsert(reg("tok", "d1"), forTokenId: "R")
    t = Date(timeIntervalSince1970: 200)          // advance past ttl
    await store.reap()
    XCTAssertTrue(await store.registrations(forTokenId: "R").isEmpty)
}
func testSetPreferencesUpdatesInPlace() async {
    let store = PushRegistrationStore(directory: tmp())
    await store.upsert(reg("tok", "d1", notifyOnFinished: false), forTokenId: "R")
    await store.setPreferences(deviceId: "d1", forTokenId: "R", enabled: true, notifyOnFinished: true)
    XCTAssertTrue(await store.registrations(forTokenId: "R").first!.notifyOnFinished)
}
```
(plus the scoping/replace/cap/removeToken cases from v1.)

- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement** the actor (≤200 lines; caps + TTL + atomic 0o600 write + injected clock).
- [ ] **Step 4: Run to verify it passes** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(server): capped, TTL-reaped, atomically-persisted PushRegistrationStore"`

---

## Task 4: handle push messages in RelayMessageHandler (validated, rate-limited)

**Files:** Modify `Sources/ClaudeRelayServer/Network/RelayMessageHandler.swift`, inject `PushRegistrationStore` via `WebSocketServer.swift`; Test `Tests/ClaudeRelayServerTests/RelayMessageHandlerTests.swift` (extend).

**Interfaces:** on `registerPushToken`: require authenticated `tokenId`; validate via `PushRegistration.isValid`; rate-limit registration mutations per connection (reuse the existing `RateLimiter` pattern or a small per-connection counter — cap e.g. 10 registrations/min); on valid → `upsert` + `pushTokenAck(accepted: true)`; on invalid/unauth/rate-limited → `pushTokenAck(accepted: false)`. `unregisterPushToken` → `remove` + ack. Registration is accepted and persisted **even if `config.pushEnabled == false`** (design decision — Task 15) so enabling push later doesn't require every device to reconnect; the store is always constructed.

- [ ] **Step 1: Failing test** — authed register → `pushTokenAck(true)` + store contains it under the conn's tokenId; oversize token → `pushTokenAck(false)` + store empty; unauth → `false`. Use the existing handler harness (`MockPTYSession`, the handler's real send helper + authed-tokenId property — grep the file for how `auth_success` is emitted).
- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement** the switch arms + validation + rate-limit; thread `pushStore` through `WebSocketServer` → `RelayMessageHandler.init`.
- [ ] **Step 4: Run to verify it passes** — `swift test --filter RelayMessageHandler` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(server): validated, rate-limited push-token registration handling"`

---

## Task 5: config keys for APNs/FCM (custom decoder + validation)

**Files:** Modify `Sources/ClaudeRelayKit/Models/RelayConfig.swift` (BOTH `CodingKeys` at line 88 AND `init(from:)` at line 93), `Sources/ClaudeRelayServer/Network/AdminRoutes.swift` (`applyConfigValue`), CLI `ConfigSetCommand` + `ConfigValue.infer`; Test `Tests/ClaudeRelayKitTests/RelayConfigTests.swift`.

**Interfaces (all optional/off by default):** `pushEnabled: Bool = false`, `pushNotifyOnFinished: Bool = false` (the **server-wide default** for devices that don't specify — per-device prefs override, design decision 3), `apnsKeyPath/apnsKeyId/apnsTeamId/apnsBundleId: String?`, `apnsUseSandbox: Bool = false`, `fcmServiceAccountPath: String?`, `fcmProjectId: String?`.

**Validation (`applyConfigValue` + CLI):** `pushEnabled`/`apnsUseSandbox`/`pushNotifyOnFinished` must be bool; when `pushEnabled=true`, at least one provider must be fully configured (all APNs fields present + readable regular file at `apnsKeyPath`, OR `fcmServiceAccountPath` readable + `fcmProjectId` present) — reject otherwise with a clear message.

- [ ] **Step 1: Failing test** — `RelayConfig.default.pushEnabled == false`; a config JSON with `apnsBundleId` round-trips through the custom decoder; a config JSON WITHOUT any push keys still decodes (back-compat); `applyConfigValue("pushEnabled","true")` accepted, `applyConfigValue("pushEnabled","yes")` rejected.
- [ ] **Step 2: Run to verify it fails** — `swift test --filter RelayConfigTests` → FAIL.
- [ ] **Step 3: Implement** — add keys to the `CodingKeys` enum AND a `decodeIfPresent ?? default` line for each in `init(from:)`; add to the CLI known-key set + `applyConfigValue` switch with the credential-combination validation.
- [ ] **Step 4: Run to verify it passes** — PASS (and existing `RelayConfigTests` still green).
- [ ] **Step 5: Commit** — `git commit -m "feat(config): APNs/FCM push config keys with credential validation (off by default)"`

---

## Task 12a: `PushHTTP` + `PushSending` (bounded, retrying transport)

**Files:** Modify `Package.swift` (add `AsyncHTTPClient`; add `Crypto` AND `_CryptoExtras` products to the `ClaudeRelayServer` target); create `Sources/ClaudeRelayServer/Push/PushSending.swift`, `Sources/ClaudeRelayServer/Push/PushHTTP.swift`; Test `Tests/ClaudeRelayServerTests/PushHTTPTests.swift`.

**Interfaces:**
- `enum PushResult: Equatable, Sendable { case delivered; case unregistered; case failed(String) }`
- `protocol PushSending: Sendable { func send(deviceToken: String, platform: PushPlatform, title: String, body: String, deepLink: String, collapseKey: String) async -> PushResult }`
- `struct CompositePushSender: PushSending` — routes by `platform` to injected APNs/FCM senders.
- `actor PushHTTP { init(client: HTTPClient, maxBodyBytes: Int = 64*1024, requestTimeout: TimeAmount = .seconds(10), maxRetries: Int = 2); func postJSON(url:headers:body:) async throws -> (status: UInt, body: Data) }` — caps response body, per-request timeout, retries 429/5xx with backoff honoring `Retry-After`/`apns-*` where present, redacts `authorization` in any thrown/logged error.

- [ ] **Step 1: Failing test** — spin a tiny local NIO/`AsyncHTTPClient`-testable mock HTTP server (or inject a fake `HTTPExecuting` seam) and assert: 200 → body returned; 503 twice then 200 → retried and succeeded; oversize body → truncated at `maxBodyBytes`; `authorization` header value never appears in a thrown error's description.
- [ ] **Step 2: Run to verify it fails** — FAIL (deps + types).
- [ ] **Step 3a: Package.swift** — add `.package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0")`, and to the `ClaudeRelayServer` target: `.product(name: "AsyncHTTPClient", package: "async-http-client")`, `.product(name: "Crypto", package: "swift-crypto")`, `.product(name: "_CryptoExtras", package: "swift-crypto")`.
- [ ] **Step 3b:** implement `PushResult`, `PushSending`, `CompositePushSender`, `PushHTTP`.
- [ ] **Step 4: Run to verify it passes** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(server): bounded, retrying push HTTP transport + PushSending protocol"`

---

## Task 12b: `APNsClient` (ES256 JWT + verified signature test)

**Files:** Create `Sources/ClaudeRelayServer/Push/APNsClient.swift`; Test `Tests/ClaudeRelayServerTests/APNsClientTests.swift`, `Tests/ClaudeRelayServerTests/APNsIntegrationTests.swift`.

**Interfaces:** `struct APNsConfig { let keyPEM, keyId, teamId, bundleId: String; let useSandbox: Bool }` (production init reads `keyPath`), `actor APNsClient: PushSending` with `init(config:http:PushHTTP, now:@Sendable ()->Date)`; internal `makeJWT(now:) throws -> String`; JWT cached ~50 min. Maps HTTP 410 (and body reason `Unregistered`/`BadDeviceToken`) → `.unregistered`.

- [ ] **Step 1: Failing tests.**
  - Unit: build JWT, split into 3, decode header `{alg:ES256,kid}`, and **verify the ES256 signature with the public key** (`P256.Signing.PublicKey.isValidSignature(_:for:)` over `header.claims`), confirm signature is raw 64-byte `r||s`. Fixture: a throwaway P-256 key (generate once, inline PEM + its public key).
  - Integration (`APNsIntegrationTests`): point `PushHTTP` at a mock server; assert path `/3/device/<token>`, headers `apns-topic`, `apns-push-type: alert`, `apns-collapse-id: <collapseKey>`, bearer present; **and decode the POSTed JSON body to assert it carries `aps.alert.title`/`aps.alert.body` AND the custom top-level `deepLink` string (round-2 fix #3 — prove tap-through data is delivered, not just headers/status)**; mock 200 → `.delivered`, mock 410 → `.unregistered`, mock 429 → retried.
- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement** `makeJWT` (ES256 via `P256.Signing.PrivateKey(pemRepresentation:).signature(for:)`, DER→raw r||s), `send(...)` via `PushHTTP`, status mapping, JWT cache. Redact bearer in logs.
- [ ] **Step 4: Run to verify it passes** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(server): APNs client (verified ES256 JWT, bounded HTTP, 410 handling)"`

---

## Task 13: `FCMClient` (RS256 → OAuth → v1, verified)

**Files:** Create `Sources/ClaudeRelayServer/Push/FCMClient.swift`; Test `Tests/ClaudeRelayServerTests/FCMClientTests.swift`, `Tests/ClaudeRelayServerTests/FCMIntegrationTests.swift`.

**Interfaces:** `actor FCMClient: PushSending` with `init(serviceAccountPath:projectId:http:PushHTTP, now:)`; mints an RS256 OAuth JWT (via `_CryptoExtras` `_RSA.Signing`), exchanges at `oauth2.googleapis.com/token` (token cached ~55 min), POSTs to `fcm.googleapis.com/v1/projects/<projectId>/messages:send` with `message.notification{title,body}`, `message.data.deepLink`, `android.collapse_key`. Maps `UNREGISTERED`/404 → `.unregistered`.

- [ ] **Step 1: Failing tests** — unit: OAuth JWT has `iss/scope/aud`, valid 3-segment RS256, **signature verified with the service-account public key**; integration (mock server): OAuth exchange caches token, v1 send maps 200→delivered / UNREGISTERED→unregistered / 401→re-mint / 5xx→retry; error-body parsing + `authorization` redaction.
- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement.** Confirm the `_CryptoExtras` RSA API name at the pinned version before use.
- [ ] **Step 4: Run to verify it passes** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(server): FCM v1 client (verified RS256 OAuth, retries)"`

---

## Task 14: `PushDispatcher` (edge detection, debounce, coalesce)

**Files:** Create `Sources/ClaudeRelayServer/Push/PushDispatcher.swift`; Test `Tests/ClaudeRelayServerTests/PushDispatcherTests.swift`.

**Interfaces (actor):**
- `init(sessionProvider: @Sendable (String) async -> [SessionInfo], tokenProvider: @Sendable (String) async -> [PushRegistration], sender: PushSending, config: PushNotifyConfig, onDeadToken: @Sendable (String) -> Void, now: @Sendable () -> Date)` — provider closures (not the live `SessionManager`) keep it pure-testable; `main.swift` wraps `listSessionsForToken`/`store.registrations`. `sessionProvider` is used ONLY for group membership / body / deep-link context, **never** as the edge source.
- **The event state is forwarded, not re-looked-up (Codex round-2 fix #1).** `func handleActivityEvent(_ event: ActivityEvent) async` where `struct ActivityEvent: Sendable { let sessionId: UUID; let tokenId: String; let agentState: AgentDetectedState?; let revision: UInt64 }`. The `agentState` is the value AT THE TIME OF THE EDGE — so a `working→blocked→idle` burst delivers three distinct events, and the blocked edge is observed even though the latest snapshot is `idle`.
- **Ordered delivery (fix #1).** Events arrive via a single `AsyncStream<ActivityEvent>` drained by ONE consumer task inside the actor, so events are processed in arrival order — not via one detached `Task {}` per event (which the round-2 review correctly flagged as unordered). `main.swift` (Task 15) yields into this stream; the consumer calls the internal `process(_:)`.
- **Per-session edge detection (Codex round-2 fix #2).** Keeps `previousSessionState: [UUID: AgentDetectedState]`. The edge is computed ON THE SESSION: fire when `prev != .blocked && event.agentState == .blocked` (blocked edge, always), or `prev == .working && event.agentState == .idle` (finish edge, per-device `notifyOnFinished`). A sibling staying `working` cannot mask this, because the aggregate rollup is NOT the edge source. Drop the event if `revision ≤ lastRevision[sessionId]` (ordering guard) BEFORE updating prior state.
- **Coalesce AFTER the edge fires.** Once a session edge fires, resolve its group (from `sessionProvider`), then debounce one push per `(tokenId, groupId)` per `debounceInterval` (default 15 s), hashed `collapseKey`. Body uses the group display `title` + `attentionCount`; deep-link = highest-severity member (tie-break lowest `id.uuidString`), scoped to `tokenId`.
- **Fan-out:** for each registration where `enabled` (and `notifyOnFinished` if it's a finish edge), `sender.send(..., collapseKey:)`; `.unregistered` → `onDeadToken(token)`.
- Caps: `previousSessionState`, `lastRevision`, debounce maps capped (e.g. 4000 sessions / 2000 groups) with age reap.

- [ ] **Step 1: Failing tests** — using a `FakeSender` actor + provider closures + injected clock (no wall-clock sleeps). Drive edges by calling `process(_:)` directly (synchronous ordering in the test):
  - `working→blocked` fires once; a second `blocked` event does NOT fire (per-session prior state).
  - **Lost-transition guard:** deliver `working`(rev1) → `blocked`(rev2) → `idle`(rev3) as three events; assert exactly ONE blocked push fired (the blocked edge is NOT lost even though the final state is idle).
  - **Sibling-masking guard:** group `/repo/a` has session A (`working`) and B (`working`); deliver B `working→idle`; assert a finish push fires (with `notifyOnFinished=true`) even though the group aggregate is still `.working` from A.
  - Two sessions blocked in one group within the window → single coalesced push, `attentionCount`-aware body, deep link points at a blocked session.
  - `working→idle` fires finish push only when a registration has `notifyOnFinished=true`.
  - Ownership isolation: a registration under token R never receives token S's push.
  - `.unregistered` result invokes `onDeadToken` with the right token.
  - Out-of-order event (`revision ≤ lastRevision[sessionId]`) is dropped.
  - **Reuse the SAME session UUID** across the event and the fake session list.

```swift
private actor FakeSender: PushSending {
    private(set) var sent: [(token: String, body: String, collapse: String, deepLink: String)] = []
    func send(deviceToken: String, platform: PushPlatform, title: String, body: String,
              deepLink: String, collapseKey: String) async -> PushResult {
        sent.append((deviceToken, body, collapseKey, deepLink)); return .delivered
    }
    func snapshot() -> [(token: String, body: String, collapse: String, deepLink: String)] { sent }
}

func testBlockedEdgeSurvivesRapidBurstToIdle() async {
    let sid = UUID(), clock = Date(timeIntervalSince1970: 0)
    let sender = FakeSender()
    let d = PushDispatcher(
        // snapshot is used only for membership/deep-link; latest state is idle here
        sessionProvider: { _ in [SessionInfo(id: sid, state: .active, tokenId: "R", createdAt: Date(),
            cols: 80, rows: 24, activity: .agentIdle, agent: "claude", agentState: .idle, workingDir: "/repo/a")] },
        tokenProvider: { _ in [PushRegistration(platform: .apns, token: "dev1", deviceId: "d1",
            enabled: true, notifyOnFinished: false, updatedAt: Date())] },
        sender: sender, config: .init(debounceInterval: 100, notifyOnFinished: false),
        onDeadToken: { _ in }, now: { clock })
    await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .working, revision: 1))
    await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .blocked, revision: 2))
    await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .idle,    revision: 3))
    let sent = await sender.snapshot()
    XCTAssertEqual(sent.count, 1, "the blocked edge must fire even though the burst ended at idle")
    XCTAssertTrue(sent[0].deepLink.contains(sid.uuidString))
    XCTAssertFalse(sent[0].collapse.contains("/repo/a"), "collapse key must be hashed, not a raw path")
}

func testFinishEdgeFiresWhenSiblingStillWorking() async {
    let a = UUID(), b = UUID(), clock = Date(timeIntervalSince1970: 0)
    let sender = FakeSender()
    let sessions = [
        SessionInfo(id: a, state: .active, tokenId: "R", createdAt: Date(), cols: 80, rows: 24,
                    activity: .agentActive, agent: "claude", agentState: .working, workingDir: "/repo/a"),
        SessionInfo(id: b, state: .active, tokenId: "R", createdAt: Date(), cols: 80, rows: 24,
                    activity: .agentIdle, agent: "claude", agentState: .idle, workingDir: "/repo/a")]
    let d = PushDispatcher(
        sessionProvider: { _ in sessions },
        tokenProvider: { _ in [PushRegistration(platform: .apns, token: "dev1", deviceId: "d1",
            enabled: true, notifyOnFinished: true, updatedAt: Date())] },
        sender: sender, config: .init(debounceInterval: 100, notifyOnFinished: true),
        onDeadToken: { _ in }, now: { clock })
    await d.process(ActivityEvent(sessionId: b, tokenId: "R", agentState: .working, revision: 1))
    await d.process(ActivityEvent(sessionId: b, tokenId: "R", agentState: .idle,    revision: 2)) // finish edge
    XCTAssertEqual(await sender.snapshot().count, 1, "one session finishing must fire even if a sibling is still working")
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement** the actor: `ActivityEvent`; a `nonisolated func enqueue(_ event: ActivityEvent)` that yields into a stored `AsyncStream.Continuation` (nonisolated so the sync `@Sendable` observer closure can call it without `await`); a single consumer task started in `init` that `for await`s the stream and calls the actor-isolated `func process(_ event: ActivityEvent) async` (exposed `internal` for tests to drive ordering synchronously); per-session `previousSessionState` + `lastRevision` with the ordering guard applied BEFORE updating prior state; the per-session edge rule; group-coalesce with hashed collapse key (`"ws_" + SHA256(groupId).hexPrefix(16)`); per-device pref gating; capped maps + age reap.
- [ ] **Step 4: Run to verify it passes** — PASS (all edge cases incl. burst + sibling).
- [ ] **Step 5: Commit** — `git commit -m "feat(server): PushDispatcher with per-session ordered edge detection + group coalescing"`

---

## Task 15: global activity observer + wire push into main.swift

**Files:** Modify `Sources/ClaudeRelayServer/Actors/SessionManager.swift` (add a **global** observer), `Sources/ClaudeRelayServer/main.swift`; Test `Tests/ClaudeRelayServerTests/SessionObserverTests.swift` (extend for the global observer).

**Interfaces (resolve v1's uncertainty — design decision):**
- Add to `SessionManager` a token-agnostic observer alongside the per-token one:
  - `typealias GlobalActivityObserver = @Sendable (_ sessionId: UUID, _ tokenId: String, _ activity: ActivityState, _ agentState: AgentDetectedState?, _ revision: UInt64) -> Void`
  - `func addGlobalActivityObserver(_ cb: @escaping GlobalActivityObserver) -> UUID` / `removeGlobalActivityObserver(id:)`
  - Invoke it inside the EXISTING `reportActivityChange` (SessionManager.swift:398-422) fan-out, passing the managed session's `tokenId`, the event `activity`/`agentState`, and the `revision` it already tracks (`activityRevision`). This forwards the actual event state (Codex round-2 fix #1) — the dispatcher never re-looks-up state and cannot lose a transition.
- `main.swift`: always construct `PushRegistrationStore` (so registration works even when push is off); construct `PushDispatcher` only when `config.pushEnabled` AND a provider is configured; the global observer **yields an `ActivityEvent` into the dispatcher's `AsyncStream`** (ordered) rather than spawning a detached `Task` per event; add TTL reap timer + `HTTPClient` shutdown in teardown.

- [ ] **Step 1: Failing test** — `addGlobalActivityObserver` receives `(sessionId, tokenId, activity, agentState, revision)` when `reportActivityChange` fires; removing it stops delivery.
- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement** the global observer (mirror the `ObserverRegistry` pattern but token-agnostic — a plain `[UUID: GlobalActivityObserver]` reaped by the existing `purgeStaleObservers`), invoke in `reportActivityChange`. Then `main.swift`:

```swift
let pushStore = PushRegistrationStore(directory: RelayConfig.configDirectory)   // always
var httpClient: HTTPClient?
var pushDispatcher: PushDispatcher?
if config.pushEnabled, let sender = try makePushSender(config: config, group: group, out: &httpClient) {
    let dispatcher = PushDispatcher(
        sessionProvider: { await sessionManager.listSessionsForToken(tokenId: $0) },
        tokenProvider:   { await pushStore.registrations(forTokenId: $0) },
        sender: sender,
        config: PushNotifyConfig(debounceInterval: 15, notifyOnFinished: config.pushNotifyOnFinished),
        onDeadToken: { token in Task { await pushStore.removeToken(token) } },
        now: Date.init)
    _ = await sessionManager.addGlobalActivityObserver { sessionId, tokenId, activity, agentState, revision in
        // Yield into the dispatcher's ordered AsyncStream — NOT a detached Task per event
        // (round-2 fix: unordered Tasks + snapshot re-read could drop a blocked edge).
        dispatcher.enqueue(ActivityEvent(sessionId: sessionId, tokenId: tokenId,
                                         agentState: agentState, revision: revision))
    }
    pushDispatcher = dispatcher
}
let pushReapTask = Task { while !Task.isCancelled {
    try? await Task.sleep(for: .seconds(6 * 3600)); await pushStore.reap() } }
// teardown near main.swift:112 → pushReapTask.cancel(); try? await httpClient?.shutdown()
```
Thread `pushStore` into `WebSocketServer`→`RelayMessageHandler`. `makePushSender` builds `CompositePushSender` from APNs/FCM per config (helper in `Push/`).

- [ ] **Step 4: Verify boot** — `swift build && swift run claude-relay restart && sleep 2 && swift run claude-relay health` → ok (push off by default; registration still accepted).
- [ ] **Step 5: Commit** — `git commit -m "feat(server): global activity observer + push pipeline wiring"`

---

## Task 16: iOS push registration, prefs, tap-through, lifecycle

**Files:** `ClaudeRelayApp/ClaudeRelayApp.swift` (+ `UIApplicationDelegateAdaptor`), `ClaudeRelayApp/Models/AppSettings.swift`, `SettingsView.swift`, `Sources/ClaudeRelayClient/` (a `registerPushToken` send + a `PushRegistrationController`), `project.yml` (entitlement); Test `Tests/ClaudeRelayClientTests/PushRegistrationControllerTests.swift`.

**Interfaces / behavior (design decisions 3 & Codex lifecycle points):**
- Settings: `@AppStorage("pushNotificationsEnabled") = true`, `@AppStorage("pushNotifyOnFinished") = false`.
- On connect + permission granted: send `registerPushToken(platform:.apns, token:, deviceId: DeviceIdentifier.current, enabled: settings.pushNotificationsEnabled, notifyOnFinished: settings.pushNotifyOnFinished)`.
- **Toggle-off suppresses delivery:** when the user turns push off (or flips finished), immediately send an updated `registerPushToken` (enabled reflecting the toggle) — or `unregisterPushToken` when fully off. A tiny testable `PushRegistrationController` decides register-vs-update-vs-unregister from (permission, settings, deviceToken, connected) so this is unit-tested.
- **Token rotation / re-auth / server switch:** re-register on `didRegisterForRemoteNotificationsWithDeviceToken`, on reconnect, and clear/re-register when the relay server or token changes (APNs tokens are environment- and app-specific — never carry a registration across servers; the store is per relay-token so switching tokens naturally scopes it).
- **Tap → deep link:** `UNUserNotificationCenterDelegate.didReceive` reads `userInfo["deepLink"]`, routes through the existing `handleDeepLink`. Handle cold-launch (launch options), background tap, and pending-nav-after-auth (store the pending URL, apply once authenticated).

- [ ] **Step 1: Failing test** — `PushRegistrationController` logic: (perm granted, enabled=true, token set, connected) → `.register(enabled:true,…)`; (enabled=false) → `.unregister`; (finished toggled) → `.register(notifyOnFinished:true)`; (not connected) → `.noop`.
- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement** the controller + settings UI (Toggle + Picker "Blocked only / Blocked & finished") + the `UIApplicationDelegateAdaptor` (request auth, register, device-token→controller, tap→deep link incl. cold launch).
- [ ] **Step 4: Add entitlement** — `aps-environment` in `project.yml` iOS target; `xcodegen generate`. **Note (human/portal):** the App ID needs Push capability enabled in the Apple Developer portal — flag in the PR.
- [ ] **Step 5: Verify on device** — push config on server, background app, drive agent to blocked → banner arrives, tap opens that session; toggle off → no further pushes.
- [ ] **Step 6: Commit** — `git commit -m "feat(ios): APNs registration w/ per-device prefs, lifecycle, tap-to-session"`

---

## Task 17: macOS push (mirror Task 16)

**Files:** `ClaudeRelayMac/…AppDelegate`, `AppSettings.swift`, `SettingsView.swift`, `project.yml`; reuse the shared `PushRegistrationController`. Test covered by Task 16's controller test.

- [ ] **Step 1:** mirror Task 16 with `NSApplication.registerForRemoteNotifications()`, macOS `aps-environment` entitlement, same controller + settings + tap→deep link.
- [ ] **Step 2:** `xcodegen generate`; verify on the Mac app.
- [ ] **Step 3: Commit** — `git commit -m "feat(mac): APNs registration, prefs, lifecycle, tap-to-session"`

---

## Task 18: Android FCM registration, prefs, tap-through

**Files:** `ClaudeRelayAndroid/app/build.gradle.kts` + project Gradle (Firebase Messaging + `google-services` plugin), `google-services.json` (see note), new `RelayFirebaseMessagingService.kt`, notification channel + manifest `<service>`, session coordinator `register_push_token` send + `PushRegistrationController` (Kotlin port), settings screen; Test `PushRegistrationControllerTest.kt`.

**Interfaces:** parity with iOS — send `registerPushToken(platform=FCM, token, deviceId, enabled, notifyOnFinished)`; `onNewToken` re-registers; toggle-off updates/unregisters; `onMessageReceived` posts a `NotificationCompat` on a created channel whose tap `PendingIntent` (FLAG_IMMUTABLE) carries `deepLink` → `DeepLinks.parseSessionId`; request `POST_NOTIFICATIONS` (API 33+).

- [ ] **Step 1: Failing test** — `PushRegistrationController` decision logic (mirror Task 16).
- [ ] **Step 2: Run to verify it fails** — `./gradlew :app:testDebugUnitTest --tests "*PushRegistrationControllerTest"` → FAIL.
- [ ] **Step 3: Implement** controller + service + settings + manifest/channel/permission.
- [ ] **Step 4:** **Note (human/console):** `google-services.json` is client config from the Firebase console; verify it is safe to commit (it is client-side config, not a secret — but confirm no server key is embedded) and that the FCM service account (server-side, secret) stays out of VCS. Add `google-services.json` handling per environment.
- [ ] **Step 5: Verify on device** — background app, drive agent to blocked → notification, tap opens session; toggle off → suppressed.
- [ ] **Step 6: Commit** — `git commit -m "feat(android): FCM registration w/ prefs, lifecycle, tap-to-session"`

---

## Task 19: docs (CLAUDE.md, README, caps, secrets)

**Files:** Modify `CLAUDE.md`, `README.md`.

- [ ] **Step 1:** document the push pipeline (register → validated handler → store → global observer → dispatcher edge-detection → APNs/FCM); the new config keys + credential-combination rules; ALL new named caps (`PushRegistrationStore` per-token + global + TTL, dispatcher prior-state/debounce caps, `PushHTTP` body/timeout/retry/concurrency limits, JWT cache lifetimes, max registration field sizes) added to the "Memory Bounds" list; secret handling (`.p8`/service-account server-only, device tokens 0o600, redaction); and the human/portal setup (Apple Push capability + `aps-environment`; Firebase project + `google-services.json` + APNs key in Firebase).
- [ ] **Step 2: Commit** — `git commit -m "docs: push notifications pipeline, caps, and setup"`

---

## Self-Review (Revision 2 — against spec + Codex findings)

**Spec coverage:** F2 (group by repo/task + worst-state badge, feeds F1) → Tasks 1,6,7,7b,8,9,10,11. F1 (push on blocked/finished, coalesced, ownership-respecting, settings, deep-link) → Tasks 2,3,4,5,12a,12b,13,14,15,16,17,18. ✅

**Codex findings — resolution ledger:**
- Wrong shim paths / `PTYSession` init / missing `await` / `PTYSessionProtocol` requirement / no `FakePTY` → fixed in Tasks 7, 8 (real paths `Sources/CPTYShim/…`, `PTYSession(sessionId:cols:rows:scrollbackSize:)`, `await`, protocol requirement + `MockPTYSession` impl). ✅
- `addActivityObserver(id:)` wrong → Task 15 adds a real, named `addGlobalActivityObserver`. ✅
- cwd tied to activity transitions misses `cd` → Task 8 refreshes on the foreground poll + `reportWorkingDir`. ✅
- cwd actor-isolation → Task 7 makes it an actor method awaited from outside; no "nonisolated" claim. ✅
- git-root grouping → Task 7b `GitRootResolver`. ✅
- `finishedUnseen` push could never fire → design decision 2 + Task 14 fire on server `working→idle` edge gated by per-device pref. ✅
- Per-device prefs → Task 2 carries `enabled`/`notifyOnFinished`; Task 3 stores them; Task 16-18 update on toggle. ✅
- TTL/caps/atomic/perms → Task 3. Input validation + rate-limit → Tasks 2/4. ✅
- `Crypto`/`_CryptoExtras` products on server target → Task 12a. Bounded/retrying HTTP → Task 12a `PushHTTP`. ✅
- Stronger crypto tests (verify signatures) + mock-HTTP integration tests → Tasks 12b/13. ✅
- Edge detection via prior-state (not debounce alone) + revision ordering → Task 14/15. ✅
- Same-UUID test bug → fixed in Task 14. ✅
- Hashed/privacy-safe collapse key → design decision 5 + Task 14. ✅
- Collapse actually implemented → Task 10 `SidebarCollapseModel` + real disclosure state. ✅
- Deep-link lifecycle (cold launch/background/post-auth/dead session) + actionable-session selection → Tasks 14 (pick+tie-break) & 16. ✅
- Disabled-mode: store always constructed, registration accepted → Task 4/15. ✅
- `google-services.json` handling + Android manifest/channel/PendingIntent flags → Task 18. ✅
- Docs of caps/secrets → Task 19. ✅

**Placeholder scan:** every code step carries real code or an exact, named edit. Remaining "match the real fixture" notes point at *verifiable* existing types (`SessionOwnershipStore` test init, handler send helper) — the implementer greps one file, not invents an API. Two genuine human/portal steps (Apple Push capability, Firebase console file) are flagged as notes, not code.

**Type consistency:** `PushResult` (single type, Task 12a onward). `PushRegistration(platform:token:deviceId:enabled:notifyOnFinished:updatedAt:)` identical across Tasks 2/3/4/14/16. `WorkspaceRollup.group(sessions:agentStates:unseen:groupKey:title:)` identical across Tasks 1/9/11. `GlobalActivityObserver` signature carries `(sessionId, tokenId, activity, agentState, revision)` — consistent Task 15 def + `ActivityEvent` in Task 14. `currentWorkingDirectory() async -> String?` on `PTYSessionProtocol` used consistently in Tasks 7/8. ✅

**Codex round-2 findings — Revision 3 ledger:**
- **Lost-transition race (fix #1):** RESOLVED. Observer forwards the event's actual `agentState`/`revision` (design decision 7, Task 15) through an ORDERED `AsyncStream` drained by one consumer (`enqueue`→`process`), not detached `Task`s + snapshot re-read. New test `testBlockedEdgeSurvivesRapidBurstToIdle` proves the blocked edge survives a `working→blocked→idle` burst. ✅
- **Aggregate finished-edge (fix #2):** RESOLVED. Edge detection is now PER-SESSION (`previousSessionState[UUID]`), not aggregate-rollup; group rollup is used only for body/count/deep-link. New test `testFinishEdgeFiresWhenSiblingStillWorking` proves a finish fires while a sibling stays `working`. ✅
- **APNs payload assertion (fix #3):** RESOLVED. `APNsIntegrationTests` now decodes the POST body and asserts `aps.alert.title/body` + top-level `deepLink`. ✅
