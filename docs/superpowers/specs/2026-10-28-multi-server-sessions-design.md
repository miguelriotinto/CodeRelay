# Multi-Server Sessions: One Workspace Across Several Relays

**Date:** 2026-10-28
**Status:** Approved 2026-10-28 (implementation plan to follow)
**Scope:** All four clients (iOS, macOS, Android, Linux), the shared Swift and
Kotlin client libraries, and a small protocol v3 change on the server.
**Related:** `2026-07-31-host-pairing-and-provisioning-design.md` (pairing adds
bookmarks this spec consumes), `2026-09-13-server-prompt-optimizer-design.md`
(per-server capabilities this spec must keep per server).

## 1. Summary

Today every CodeRelay client is a one-server app with a multi-server address
book. Bookmarks, keychain tokens, pairing and the status poller already handle
any number of relays, but the moment the user taps "Connect" the app builds
exactly one coordinator around exactly one WebSocket, and everything downstream
assumes that: one `activeSessionId`, one recovery loop, one sidebar, caches
keyed by a bare session UUID. To reach a session on a second machine the user
leaves the workspace, picks the other server, and loses sight of the first.

This spec makes the workspace show every enabled server at once: three
sessions from `server1` and two from `server2` in one sidebar, grouped by
server, each selectable directly, with live agent-state dots for all of them
and cached, greyed rows for a server that is currently unreachable.

The design adds one layer and changes almost nothing beneath it. A new
`ServerHub` owns one **unchanged** per-server coordinator for each enabled
bookmark, merges their published state into per-server sections, and holds the
single global "active session" as a `(server, session)` pair. The hardened
per-server code (RPC correlation with no request ids, recovery, handshake,
keepalive, push registration) stays exactly where it is and keeps its tests.

On the server, protocol v3 adds a persisted **server instance id** and a
display name to `auth_success` and `pair_success`, puts the same id into push
payloads and deep links, and namespaces the push collapse key by it. Old v2
servers keep working with reduced push routing; a one-server user sees no
behavioural change at all.

## 2. Goals and non-goals

### Goals

- G1. Sessions from every enabled server are visible and selectable in one
  workspace, grouped by server, without a "connect to a server" step.
- G2. Every enabled server is live while the app is foregrounded: session
  lists, agent-state dots, workspace rollups and in-app notifications stay
  current for all of them.
- G3. Exactly one session is attached at any time across all servers, as
  today within one server; switching across servers is one tap.
- G4. A server that is unreachable keeps its last known sessions on screen,
  marked offline; selecting one triggers that server's recovery only.
- G5. Push notifications from N servers route the tap to the right server and
  no longer collapse into each other across servers.
- G6. Per-server behaviour that is already correct stays per server: auth
  errors, optimizer capability, recovery, rate limits, token revocation.
- G7. Identical shape on all four clients; the Kotlin twin is one
  implementation shared by Android and Linux as today.
- G8. A user with one bookmark sees no change in behaviour, latency or UI
  beyond the section header.

### Non-goals

- Server-to-server federation or a "home" relay proxying others. Servers stay
  independent and mutually unaware.
- Moving a session between servers, or cross-server session search.
- Attaching more than one session at once (split view). The hub's single
  active ref is a deliberate match to today's model; split view would be its
  own spec on top of this one.
- Changing how tokens work: one relay token per bookmark, minted by that
  server, stored per bookmark as today.
- Per-server settings beyond "enabled in workspace" and the display name.
- Background connectivity on mobile beyond what the OS already allows; push
  remains the background channel.

## 3. Decisions and rationale

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| D1 | Connectivity model | One live WebSocket per enabled server while foregrounded | User choice. Live dots, rollups and activity for every server; the only cost is N keepalives (one small JSON ping per server every 10 s). |
| D2 | Sidebar presentation | Grouped by server, collapsible sections | User choice. Keeps today's rows, rollups and tiles intact inside each section; server identity is visible without a badge on every row. |
| D3 | Platform scope | All four clients, one spec, phased plan | User choice. Kotlin modules are shared by Android and Linux, so the design must be right once. |
| D4 | Offline server | Show cached list, marked offline | User choice. Nothing disappears or reshuffles; selecting a cached row is the natural "reconnect" affordance. |
| D5 | Architecture | `ServerHub` over per-server coordinators | Approved. The per-server coordinator took six fixes to stabilise (ownership, delivery, socket lifecycle, RPC correlation). Wrapping it isolates the new risk to one layer; re-keying it would re-open every hardened path on four clients. |
| D6 | Server identity on the wire | Protocol v3: persisted instance id + name in `auth_success`/`pair_success`, id in push payloads, collapse key namespaced | Approved. Without it a push from either of two servers is ambiguous and two checkouts of the same path overwrite each other's notifications. Client works without it (local bookmark id) so old servers degrade gracefully. |
| D7 | Session addressing | `SessionRef(serverId, sessionId)` where `serverId` is the bookmark's existing local UUID | Session UUIDs are ephemeral and server-scoped; only the local bookmark id is stable and already keys the keychain and status map. The server instance id is **not** the key: it is unknown until the first v3 handshake and absent on v2 servers. |
| D8 | Per-server persistence | Namespace each coordinator's `SessionOwnershipStore` by `serverId` instead of re-keying its maps | Coordinator internals stay UUID-keyed because every map is already per connection. Only the hub-level active session needs a `SessionRef`. Migration is a one-time key-prefix copy. |
| D9 | Attachment invariant | Hub serialises "detach on A, then attach on B" | Server allows one attached session per connection; across connections nothing stops two attachments, so the client must. One attached session is also what the clipboard gate and the optimizer wand assume. |
| D10 | Reconnect fan-out | Staggered by ~150 ms per server, recovery jitter kept | N servers reconnecting in lockstep on wake is the macOS poller storm with extra steps. |
| D11 | Status polling | `ServerStatusChecker` retired for enabled servers; the live connection *is* the status | Two probes per server (hub connection + 15 s poller) doubled connection churn and the poller is where the earlier reconnect storm lived. Kept only for disabled bookmarks on the management screen. |
| D12 | Cap | 8 enabled servers | Matches the terminal-view cache bound and keeps the keepalive and reconnect budget trivially small. Not a hard architectural limit. |

## 4. Architecture

```
                         ┌────────────────────────────────────────┐
   UI (sidebar sections, │              ServerHub                 │  one per app
   terminal pane, menu   │  sections: [ServerSection]             │
   bar, notifications)   │  activeRef: SessionRef?                │
          ▲              │  aggregate: counts across servers      │
          │ observes     │  select(ref) / createSession(on:)      │
          │              │  handleForegroundTransition() → fan-out│
          │              └──────┬──────────────┬─────────────┬────┘
          │                     │ owns         │             │
          │              ┌──────▼──────┐ ┌─────▼──────┐ ┌────▼───────┐
          │              │ Coordinator │ │ Coordinator│ │ Coordinator│  one per
          └──────────────│  server A   │ │  server B  │ │  server C  │  enabled
                         │ (unchanged) │ │ (unchanged)│ │ (disabled: │  bookmark
                         └──────┬──────┘ └─────┬──────┘ │  not built)│
                                │              │        └────────────┘
                         RelayConnection  RelayConnection
                         SessionController SessionController
                         RecoveryController RecoveryController
                         SessionHandshake  SessionHandshake
                         ActivityCoordinator ActivityCoordinator
                         OwnershipStore(ns A) OwnershipStore(ns B)
                                │              │
                             ws(s)://A      ws(s)://B      ← independent relays,
                                                              protocol v3 or v2
```

The hub is the only new concept. Each coordinator is today's
`SharedSessionCoordinator` (Swift) or `relay.session.SessionCoordinator`
(Kotlin), constructed by the same platform subclass or factory as now, with
three small additions described in §7.4. Everything the UI used to read from
"the coordinator" it now reads from the hub, which either aggregates across
coordinators (sections, counts) or forwards to the coordinator that owns
`activeRef` (terminal view, load phase, optimizer state, clipboard).

## 5. Identity model

### 5.1 `SessionRef`

```swift
public struct SessionRef: Hashable, Codable, Sendable {
    public let serverId: UUID      // ConnectionConfig.id — the local bookmark
    public let sessionId: UUID     // SessionInfo.id — ephemeral, server-scoped
}
```

Kotlin: `data class SessionRef(val serverId: UUID, val sessionId: UUID)` in
`core-protocol` next to `ConnectionConfig`.

Used by: the hub's `activeRef`, last-session restore, deep-link routing, UI
selection, and tests. **Not** used inside a coordinator, whose maps stay keyed
by `UUID` because they belong to one connection.

### 5.2 Server identity: two ids, one job each

| Id | Where it lives | Stable across | Used for |
|----|----------------|---------------|----------|
| `ConnectionConfig.id` (bookmark id) | Client, `SavedConnectionStore` | App reinstall only if bookmarks are restored | Keychain account, status map, `SessionRef.serverId`, ownership-store namespace, hub section identity |
| `serverInstanceId` (new) | Server, `~/.claude-relay/instance.json`; mirrored onto the bookmark after the first v3 handshake (`ConnectionConfig.instanceId: UUID?`) | Server restarts, host renames, port changes | Push deep-link routing, duplicate-bookmark detection, menu bar / notification labels when `serverName` is set |

The bookmark id stays the key because it exists before any connection and on
every protocol version. The instance id is a property of the bookmark that is
learned, never a key.

### 5.3 Session UUIDs

`SessionManager` mints `UUID()` per session and persists nothing; a server
restart replaces every id. The hub therefore treats a server's cached rows as
a snapshot that is **replaced** by the first fresh `session_list` after a
reconnect, never merged. Collisions between servers are a UUID v4
non-event, but nothing relies on their absence: every lookup goes through a
`SessionRef` or through the owning coordinator.

## 6. Server changes and wire protocol v3

### 6.1 Persisted instance identity

- New file `RelayConfig.instanceFile` = `~/.claude-relay/instance.json`,
  `{"id":"<uuid>","createdAt":"<iso8601>"}`, written `0o600` at startup when
  missing. A corrupt file is replaced and logged at error, not fatal
  (`ConfigManager.load()` already treats a corrupt `config.json` the same way).
- New optional config key `serverName` (string). Validation in
  `AdminRoutes.applyConfigValue()` and `ConfigSetCommand`: control characters
  and newlines stripped, capped at 60 scalars, the pairing-label sanitiser
  reused verbatim. Default when unset: the host name
  (`ProcessInfo.processInfo.hostName` on both platforms, trimmed of `.local`).
- `GET /status` gains `instanceId` and `serverName`; `claude-relay status`
  prints both. `/health` unchanged.

### 6.2 Protocol bump

`CodeRelayKit.protocolVersion` becomes 3. `minProtocolVersion` stays 0.

| Message | Change | Notes |
|---------|--------|-------|
| `auth_success` | `+ serverId: String?`, `+ serverName: String?` | Both nil on v2 servers; clients key nothing on them. |
| `pair_success` | `+ serverId: String?`, `+ serverName: String?` | Lets pairing dedupe and pre-name the bookmark before the first auth. |
| `register_push_token` | unchanged | The connection identifies the server. |
| push payloads (APNs custom keys / FCM `data`) | `+ serverId`, `deepLink` gains `?server=<instanceId>` | §10. |
| everything else | unchanged | `session_activity`, `session_list_result`, binary frames are connection-scoped already. |

`auth_success` already carries `capabilities`; no new capability string is
needed because presence of `serverId` is the feature test. Clients continue to
send `protocolVersion: 3` in `auth_request`; servers accept any version ≥ 0 as
today.

### 6.3 Push collapse key

`PushDispatcher.collapseKey(for:)` becomes
`"ws_" + sha256(instanceId + "\n" + groupId).prefix(16)`. Two hosts with a
checkout at the same path now produce distinct `apns-collapse-id` /
`collapse_key` values and distinct APNs `thread-id`s, so their notifications
stack instead of replacing each other. The value is still a hash: the raw path
never leaves the host (existing privacy rule preserved).

### 6.4 Admin API

No new endpoints. Pairing (`POST /pair/create`) is unchanged on the admin side;
the `pair_success` additions above are produced by `RelayMessageHandler` from
the same instance identity.

## 7. `ServerHub` (shared design, Swift and Kotlin)

### 7.1 Responsibilities

1. Build and hold exactly one coordinator per **enabled** bookmark; tear it
   down when the bookmark is disabled or removed.
2. Publish per-server sections and a cross-server aggregate for the UI.
3. Own `activeRef` and enforce the single-attachment invariant.
4. Fan lifecycle events out (foreground, wake, network change, push token
   rotation, settings changes) with a stagger.
5. Route deep links and notification taps to the owning coordinator.
6. Persist and restore `activeRef`.

It does **not** talk to the network, run recovery, decode messages or hold
terminal views. Those remain coordinator concerns.

### 7.2 Published state

```swift
@MainActor public final class ServerHub: ObservableObject {
    @Published public private(set) var sections: [ServerSection]
    @Published public private(set) var activeRef: SessionRef?
    @Published public private(set) var aggregate: HubAggregate
    public var activeCoordinator: SharedSessionCoordinator? { get }
}

public struct ServerSection: Identifiable {
    public let id: UUID                       // bookmark id
    public var config: ConnectionConfig       // name, host, port, tls, instanceId?
    public var status: ServerSectionStatus    // connecting | live(quality) | reconnecting(attempt) | offline(since) | authFailed(message) | disabled
    public var sessions: [SessionInfo]        // live list, or last cached list when offline
    public var isCached: Bool                 // true while `status` is not live
    public var rollups: [WorkspaceRollup]     // per server, from its ActivityCoordinator
    public var awaitingInput: Int
    public var isCollapsed: Bool              // persisted per device
}

public struct HubAggregate {
    public var liveServers: Int, totalServers: Int
    public var sessionsAwaitingInput: Int
    public var workingSessions: Int
}
```

Kotlin: `StateFlow<List<ServerSection>>`, `StateFlow<SessionRef?>`,
`StateFlow<HubAggregate>` on `relay.session.ServerHub` in `core-session`.

Section ordering: bookmark order from `SavedConnectionStore` (user-arranged
on the management screen), never by status, so the list does not jump when a
server drops.

### 7.3 Lifecycle

```
start()                     load bookmarks → for each enabled, stagger(i*150ms) → build coordinator → coordinator.start()
                            restore activeRef (§9) → if its server is enabled, select(ref, reason: .restore)
setEnabled(serverId, true)  build + start coordinator; section appears with status .connecting
setEnabled(serverId, false) if activeRef.serverId == serverId: detach + clear activeRef
                            coordinator.shutdown() (unregisters push on that server first if reachable) → section status .disabled, cached list kept
removeServer(serverId)      setEnabled(false) → delete token (AuthManager) → delete ownership namespace → remove bookmark
handleForegroundTransition  for each live coordinator, stagger(i*150ms): coordinator.handleForegroundTransition()
systemDidWake / network up  same fan-out; coordinators keep their own breakers and backoff
stop()                      detach active (best-effort, 2 s budget), shutdown every coordinator
```

Building a coordinator uses the platform's existing factory (the iOS/macOS
`SessionCoordinator` subclasses, Android `ConnectionViewModel`'s construction
path, Linux `ConnectionSession`), so platform glue (`SleepWakeObserver`,
`scenePhase`, `NetworkObserver`) attaches once per coordinator exactly as it
does today. The hub registers itself, not a coordinator, with
`ActiveCoordinatorRegistry` on macOS (§8.3).

### 7.4 Coordinator additions (the only changes to the per-server unit)

1. **`ownershipNamespace`**: the coordinator's `SessionOwnershipStore` is
   constructed with `keyPrefix: "<appPrefix>.<serverId>"`. Nothing else in the
   coordinator changes; names, agents and collapsed groups are now per server
   by construction.
2. **`detachActive() async`**: a public, idempotent "detach whatever is
   attached and clear `activeSessionId`" that the hub awaits before attaching
   on another server. Today's internal switch path already does this between
   two sessions on one server; this exposes it with a 3 s budget and a
   generation guard so a stuck server cannot block the switch (the hub
   proceeds and the stale coordinator's recovery reconciles later).
3. **`serverIdentity`**: `(instanceId: UUID?, name: String?)` published after
   `auth_success`, mirrored onto the bookmark by the hub.

The clipboard gate, optimizer availability, load phase, F3 restore flag and
`isForeignError` logic are untouched: because the hub guarantees that at most
one coordinator has a non-nil `activeSessionId`, each of those checks remains
correct within its own coordinator.

### 7.5 Selection and the single-attachment invariant

```
select(ref):
  guard section(ref.serverId) exists
  if activeRef == ref: return
  let from = activeRef.map(coordinator(for:)), to = coordinator(for: ref.serverId)
  activeRef = ref                                    // UI switches immediately; terminal pane shows `to`'s cached view or load overlay
  if from !== to { await from?.detachActive() }      // bounded, generation-guarded
  if to.status is live: await to.switchToSession(ref.sessionId)   // existing path: detach-if-needed, attach with grid, replay
  else: to.pendingSelection = ref.sessionId; to.triggerUserRecovery()   // D4: selecting a cached row is the reconnect gesture
```

Within one server, `select` degrades to today's `switchToSession`. Across
servers the only new step is the awaited `detachActive()` on the previous
coordinator. If the previous server is offline the detach is skipped (there is
nothing attached) and the attach proceeds at once.

`createSession(on serverId)` is `select`'s twin: detach elsewhere, then the
owning coordinator's existing `createNewSession` with the current grid.

### 7.6 Aggregation rules

- `awaitingInput`, `workingSessions`, badge counts: sums over sections whose
  status is live. Cached sections contribute zero (their state is stale).
- Workspace rollups are per server (D2); the hub never merges two servers'
  rollups even when `workingDir` matches.
- The Mac menu bar and Linux `notify-send` label items `"<serverName> · <session>"`
  when more than one server is enabled, `"<session>"` otherwise (G8).
- `sessionLoadPhase` shown by the overlay is `activeCoordinator?.sessionLoadPhase`.
  Non-active servers' connecting/authenticating phases are rendered as the
  section's status, never as the overlay.

### 7.7 Reconnect budget

With N ≤ 8 live connections: N pings per 10 s, N `session_list` refreshes per
foreground transition, staggered. Each coordinator's `RecoveryController`
keeps its breaker and exponential backoff; the hub adds only the initial
stagger and does not retry on a coordinator's behalf. Idle reaping (60 s
server-side) is unaffected because each connection pings independently.

## 8. Clients

### 8.1 Shared behaviour (all four)

- Root screen is the workspace. With zero bookmarks it shows the existing
  add/pair empty state. "Connect" as a navigation step is gone; servers are
  enabled or disabled.
- Sidebar: one `ServerSectionHeader` per section (name, status dot or
  spinner, offline/auth-failed badge, awaiting-input count, collapse chevron),
  then the unchanged session rows / workspace tiles for that server. Offline
  sections render rows at reduced opacity with an "offline, last seen …" line.
- Tapping a row calls `hub.select(ref)`. The "new session" affordance lives in
  each section header (and keeps the keyboard shortcut, which targets the
  active server, or the only server).
- Server management screen (today's server list) gains an "Enabled" toggle
  per bookmark, shows `serverName`/instance id when known, flags duplicate
  instance ids, and keeps add/edit/pair/delete. It no longer has a Connect
  button.
- Reconnecting sheet: shown only when the **active** server is in recovery;
  other servers' recovery is a section status. The sheet names the server.
- Auth failure on one server: section status `authFailed(message)` with a
  "Re-pair" action; no global logout, no other server affected (G6).
- Settings: a single "auto-connect on launch" setting is replaced by the
  per-bookmark Enabled toggle; `lastConnectedServerId` is retired (§9).

### 8.2 iOS (`CodeRelayApp/`)

- `ServerListView` stops being the launch screen and stops owning
  `activeConnection`/`activeToken`/`connectedServerId` (`ServerListViewModel`
  lines 17–19); it becomes the management screen reached from Settings or the
  sidebar header.
- `WorkspaceView` is presented at root with an `@StateObject` `ServerHub`
  owned by the app (`CodeRelayApp.swift`), not by a view that can be
  recreated. The `fullScreenCover` navigation and `isNavigatingToWorkspace`
  go away.
- `SessionSidebarView` renders sections; iPhone Duo layout rules from the Duo
  work are unchanged (sections are content inside the existing pane).
- Deep link (`CodeRelayApp.handleDeepLink`): `coderelay://session/<uuid>?server=<id>`
  → `hub.handleDeepLink(sessionId, instanceId)`. If no coordinator is live yet,
  the hub queues it until `start()` completes (replaces `pendingSessionId` and
  the "connect to the first server" fallback in `ServerListView:126`).
- `scenePhase` → `hub.handleForegroundTransition()`.

### 8.3 macOS (`CodeRelayMac/`)

- `MainWindow.coordinator` becomes `MainWindow.hub`; the sidebar renders
  sections; the detail pane shows `hub.activeCoordinator`'s terminal view.
- `ActiveCoordinatorRegistry` registers the hub. `MenuBarViewModel` follows
  `hub.aggregate` for the status colour (green if the active server is live
  and no server is `authFailed`; orange if any enabled server is reconnecting;
  red if all are offline) and lists sessions grouped by server in
  `MenuBarDropdown`.
- `ServerListWindow` becomes the management window (toggle, no Connect).
- `SleepWakeObserver.systemDidWake` → `hub.handleForegroundTransition()`
  (which fans out) instead of one coordinator's `triggerUserRecovery()`.
- Native tabs: a tab is bound to a `SessionRef`; opening a tab for a session on
  another server is `select` with the usual detach-then-attach.

### 8.4 Android (`CodeRelayAndroid/`)

- `ConnectionViewModel` becomes the owner of one `ServerHub`; its
  `connect(...)`/`teardown()` pair is replaced by `hub.start()` on process
  start and `setEnabled` from the management screen. `RelayNavGraph` starts at
  the workspace; `ServersScreen` is management.
- `WorkspaceScreen` collects `hub.sections`/`hub.activeRef`; `SessionSidebar`
  gets the section header composable; the two-pane `Row` layout from PR #68 is
  unchanged.
- `MainActivity.pendingSessionId` becomes a pending `(sessionId, instanceId?)`
  pair handed to `hub.handleDeepLink`. `DeepLinks.parseSessionId` learns the
  `server` query parameter; `DeepLinks.sessionUri` is unchanged for internal
  use.
- `RelayFirebaseMessagingService` passes `data.serverId` and the full
  `deepLink` through unchanged; `FcmTokenBridge` stays a process singleton and
  the hub fans the token to every live coordinator's `syncPushRegistration`.
- `NetworkObserver` is shared; its callback goes to the hub.

### 8.5 Linux (`CodeRelayLinux/`)

- `Main.kt`'s `var session: ConnectionSession?` and `connectTo(config)` are
  replaced by a `ServerHub` created once per process. `ConnectionSession`
  becomes the per-server coordinator factory the hub calls.
- `DesktopNotifier` prefixes the server name when more than one server is
  enabled; click-to-focus (`--action`) carries the `SessionRef`.
- Accelerators: existing chords unchanged; `Ctrl+Shift+Up/Down` move the
  selection across section boundaries like any row. No new chords.
- `SingleInstance` argv forwarding passes deep links through to the hub.

## 9. Persistence and migration

| Datum | Today | After |
|-------|-------|-------|
| Bookmarks | `SavedConnectionStore` array | Same, each `ConnectionConfig` gains `enabled: Bool` (default true for the migrated last-connected bookmark, **false** for others — see below) and `instanceId: UUID?`, `displayName: String?` |
| Tokens | Keychain / keyring per bookmark id | Unchanged |
| Session names, agent map, collapsed groups | `<prefix>.sessionNames`, `<prefix>.agentSessions`, `<prefix>.collapsedGroups.<deviceId>` | `<prefix>.<serverId>.…` per coordinator |
| Active session (F3 restore) | `<prefix>.activeSession.<deviceId>` holding a UUID | `<prefix>.activeRef.<deviceId>` holding a `SessionRef` |
| Last connected server | `lastConnectedServerId` (iOS, Android, Linux), `com.clauderelay.mac.lastServerId` (macOS) | Retired after migration |
| Section collapse state | n/a | `<prefix>.hub.collapsedServers.<deviceId>` |

Migration runs once at first `hub.start()` on a build with this feature, is
idempotent, and is guarded by a `<prefix>.hub.migrated` flag:

1. Read `lastConnectedServerId`. If it names an existing bookmark `S`, copy
   the legacy names/agents/collapsed-groups keys into `S`'s namespace, set
   `S.enabled = true`, and convert the legacy active-session UUID into
   `SessionRef(S, uuid)`. Every other bookmark gets `enabled = false`.
2. If it names no bookmark (or is empty): legacy maps are dropped (they
   belonged to a server that no longer exists), and the bookmark list is left
   with `enabled = false` everywhere except when there is exactly one bookmark,
   which is enabled.
3. Delete the legacy keys.

Enabling only the previously used server is deliberate: it makes the upgrade
observably identical to today (G8) and leaves turning on other servers as an
explicit, discoverable action on the management screen.

## 10. Push notifications and deep links

- Registration: `hub.syncPushRegistration(token, permission, deviceId, prefs)`
  calls each **live** coordinator's existing `syncPushRegistration`. The
  `PushRegistrationController` decision logic is unchanged and runs per server.
  Disabling or removing a server sends `unregister` on that server first when
  it is reachable; otherwise the server's 90-day TTL reaps the registration.
- Payload (server, §6): APNs custom keys `deepLink`, `serverId`; FCM `data`
  `deepLink`, `serverId`; `thread-id`/collapse key namespaced by instance id.
- Deep link format: `coderelay://session/<uuid>?server=<instanceId>`.
  `server` is optional for backward compatibility with v2 servers and with
  links typed by hand.
- Routing (`hub.handleDeepLink(sessionId, instanceId?)`):
  1. If `instanceId` matches a bookmark's mirrored `instanceId`, target that
     server. If that bookmark is disabled, enable it for this selection and
     tell the user ("Enabled <name> to open this session").
  2. Else search every live section's session list for `sessionId`; a unique
     hit wins.
  3. Else, if exactly one server is enabled, hand it to that coordinator's
     existing `attachRemoteSession` (cross-device attach via `session_list_all`).
  4. Else show the existing "session not found" notice naming the server if
     known.
- Pairing: `pair_success.serverId` is written to the new bookmark before the
  first auth. If a bookmark with that instance id already exists, the user is
  asked whether to replace its host/port (the server moved) or keep both (two
  routes to one server, flagged on the management screen).

## 11. Pairing and server management

- `PairingController` is unchanged except for reading the two new
  `pair_success` fields. Pairing never touches live coordinators; the hub
  observes `SavedConnectionStore` and builds the coordinator when the new
  bookmark is enabled (paired bookmarks default to enabled).
- Editing a bookmark's host/port/TLS while it is enabled tears down and
  rebuilds its coordinator (same as toggling); its ownership namespace is
  keyed by bookmark id so names survive the edit.
- Deleting the active server's bookmark runs `removeServer`, which detaches
  first (§7.3).

## 12. Error handling and edge cases

| Situation | Behaviour |
|-----------|-----------|
| Server unreachable at start | Section `.connecting` → `.offline(since)` after the coordinator's existing timeout; cached rows shown; recovery continues on the coordinator's backoff. |
| Active server drops mid-session | Today's behaviour inside that coordinator (Reconnecting sheet, resume). Other sections unaffected. |
| Token revoked on server B | B's coordinator reports auth failure → section `.authFailed("Token rejected")` with Re-pair. No global state changes. |
| Selecting a cached row on an offline server | `pendingSelection` stored; user recovery triggered; on success the coordinator switches to the pending session if it still exists, else shows the fresh list and a "session ended" notice. |
| Server restarted (all session ids new) | First fresh list replaces cached rows; `activeRef` pointing at a vanished id is cleared with the existing "session ended" path; F3 restore skips refs whose session is absent. |
| Two bookmarks resolve to one instance id | Management screen flags both; the hub still builds both coordinators (they are independent sockets) but push routing picks the first enabled one. |
| `detachActive()` on previous server hangs | 3 s budget; hub proceeds to attach on the new server; the old coordinator's generation guard discards the late detach reply and its recovery reconciles state. The server side tolerates a dangling attach (detach timeout, idle reaper). |
| Cross-server switch while the previous server is already reconnecting | Skip detach (nothing attached); attach proceeds. |
| Deep link for a disabled server | Enable-and-open with a notice (§10). |
| More than 8 enabled | Management screen refuses the ninth toggle with an explanation. |
| App backgrounded (iOS/Android) | OS suspends sockets; on return the hub fans out `handleForegroundTransition` with stagger; each coordinator's "alive short-circuit" applies, so healthy servers only refetch lists. |
| Low-memory / terminal cache | `TerminalCache` stays per coordinator (LRU 8), and the hub bounds the **total** across coordinators to 8 cached views: when a selection would exceed it, the least-recently-selected view on a non-active coordinator is dropped first. Coordinators offline for over 30 minutes drop all cached views. |

Hub operations never throw to the UI; failures surface as section status or
the existing per-coordinator notices. The hub logs under a new `hub` category.

## 13. Security and privacy

- Tokens remain per bookmark in the keychain / Secret Service; the hub never
  holds them beyond passing one to the coordinator it builds.
- ATS / cleartext rules are evaluated per connection exactly as today; one
  server requiring `wss://` does not affect another.
- The instance id is a random UUID with no host information; `serverName`
  defaults to the host name, which the operator can override, and is
  sanitised like pairing labels because it reaches logs and notifications.
- Push payloads gain only the opaque instance id; the collapse key stays a
  hash. No path or session content is added.
- Rate limits are per server and per IP; a device with N servers has N
  independent auth budgets, which is correct since each is a separate trust
  domain.

## 14. Performance budget

| Item | Per enabled server | 8 servers |
|------|--------------------|-----------|
| Keepalive | 1 JSON ping / 10 s | 0.8 msg/s |
| Foreground refetch | 1 `session_list` | 8 requests over ~1.2 s (stagger) |
| Memory | one coordinator's state + cached session list; terminal views are the only large objects | 8 cached terminal views in total across the hub (§12), so roughly today's footprint plus seven small coordinators |
| Battery (mobile) | sockets are suspended in background; cost is foreground only | — |

Scrollback replay is unchanged: only the active session streams output.

## 15. Testing

### 15.1 Shared library (Swift `CodeRelayClientTests`, Kotlin `core-session` tests)

- `ServerHubTests` with a `FakeCoordinator` protocol double (status, sessions,
  `detachActive` spy, `switchToSession` spy, failure injection):
  - builds one coordinator per enabled bookmark; none for disabled.
  - `select` across servers calls `detachActive` on the previous coordinator
    **before** `switchToSession` on the next, and not within one server.
  - `detachActive` hang → attach proceeds after the budget.
  - offline section keeps cached rows; first fresh list replaces them.
  - aggregate counts ignore cached sections.
  - stagger ordering on `start()` and `handleForegroundTransition()`.
  - deep-link routing precedence (instance id → unique session → single
    server → not found), including enable-on-demand.
  - migration: legacy keys → namespaced keys, active UUID → `SessionRef`,
    enabled flags, idempotency, missing last-server case.
- `SessionRef` codable round trip; `ConnectionConfig` decoding of pre-feature
  bookmarks (missing `enabled`/`instanceId`).
- Coordinator additions: `detachActive` idempotency and generation guard;
  `serverIdentity` published from `auth_success`; ownership namespace
  isolation (two coordinators, same session UUID, different names).

### 15.2 Server (`CodeRelayServerTests`, Linux job included)

- Instance file created with `0o600`, reused across restarts, replaced when
  corrupt.
- `auth_success` / `pair_success` carry `serverId`/`serverName`; `serverName`
  sanitiser; config validation of `serverName`.
- `collapseKey` differs for same `groupId` on different instance ids and is
  stable for one instance.
- APNs/FCM payload builders include `serverId` and the `?server=` deep link
  (existing `APNsClientTests`/`FCMClientTests` fixtures).
- `/status` includes the new fields.
- Wire tests (`WireIntegrationTests`): a v2-style client (no new fields
  expected) still authenticates; two in-process servers on random ports can be
  driven by one hub through `TestWebSocketClient`-backed coordinators.

### 15.3 Apps

- iOS/macOS: the `#if DEBUG` env-var harness seeds hub state (three sections,
  one offline, one auth-failed) for screenshot verification, since simulator
  taps are unavailable here. Deep-link routing exercised with `xcrun simctl openurl`.
- Android: existing emulator recipe; two relays (host + a second port) paired,
  verify section rendering, cross-server switch, FCM tap routing via
  `adb shell am start -a VIEW -d "coderelay://session/<uuid>?server=<id>"`.
- Linux: `./gradlew test` for the shared modules; manual two-relay run.
- Regression gate: all existing coordinator, recovery, handshake and RPC tests
  pass unchanged (the coordinator API is additive).

## 16. Rollout and plan decomposition

Each phase is independently shippable and leaves a one-server user unchanged.

| Phase | Scope | Exit criterion |
|-------|-------|----------------|
| 0 | Server + Kit: instance file, `serverName`, protocol v3 fields, push payload + collapse key, `/status`, CLI output, docs | Server tests green on macOS and Linux; a v2 client still connects; Homebrew/AUR release |
| 1 | Swift `ServerHub`, `SessionRef`, coordinator additions, migration; macOS UI (sidebar sections, management window, menu bar, deep links) | macOS app drives two relays; TestFlight build |
| 2 | iOS UI on the same hub (root workspace, sections, management, deep links, scenePhase fan-out) | iOS TestFlight; Duo layout unaffected |
| 3 | Kotlin `ServerHub` + `SessionRef`, coordinator additions, migration; Linux `Main.kt`, sidebar, notifier | Linux client drives two relays; `./gradlew test` green on CI |
| 4 | Android: nav graph, `ConnectionViewModel` → hub, FCM routing, management screen | APK on GitHub Releases; FCM tap opens the right server |

Phase 1 before 2 because macOS is where multi-server will be used most and is
the fastest to verify end to end; phases 3 and 4 share one Kotlin
implementation, so 4 is mostly Android glue.

## 17. Known limits and risks

- **One attached session.** Switching servers still detaches the previous
  session; its output is buffered server-side in the ring buffer and replayed
  on return, as today within one server. Split view is out of scope.
- **Mobile background.** iOS and Android suspend sockets; a server's section
  may show stale state until foreground. Push covers "needs input" and
  "finished" as today.
- **Server-restart churn.** Because session ids are ephemeral, a restarted
  server's cached rows are replaced wholesale; names persist only through the
  server-side session-name feature, unchanged.
- **Mixed protocol versions.** Against a v2 server, push taps rely on the
  local session index (step 2 of routing), which fails if two servers happen
  to be configured and the session list has not loaded yet; the user is told
  which server, if known. Upgrading the server removes the ambiguity.
- **Blast radius.** The hub is new code on four clients; the per-server unit
  changes in three small, additive ways. The main regression risk is the
  macOS `ActiveCoordinatorRegistry`/menu-bar wiring and the iOS navigation
  change, both covered by the harness screenshots and the existing tests.
- **Cap of 8** is a product choice, not a technical ceiling; raising it means
  revisiting the terminal cache bound and the stagger.
