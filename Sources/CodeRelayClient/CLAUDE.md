# CodeRelayClient — notes for Claude Code

Shared Apple client library: transport (`RelayConnection`), per-server session
lifecycle (`SharedSessionCoordinator`), the multi-server hub (`Hub/`), and the
UI atoms both apps host (`Views/`).

## ServerHub (multi-server; spec `docs/superpowers/specs/2026-10-28-multi-server-sessions-design.md`)

- `ServerHub<Slot: ServerSlotCoordinating>` owns one coordinator per **enabled**
  bookmark, built by an injected factory, and the one global
  `activeRef: SessionRef` (bookmark id + session id). The server **instance id**
  (`ConnectionConfig.instanceId`, learned from `auth_success`) is for duplicate
  flagging and deep-link routing only — never a key.
- Coordinators are unchanged apart from four additive hooks:
  `ownershipKeyPrefix` (per-server names/agents/collapsed-groups namespace, D8),
  `detachActive()` (bounded by `detachBudget` through `BoundedWait`),
  `serverIdentity`, `isAuthRejected`. Hub tests run against `FakeServerSlot`.
- **One attachment across all servers.** A cross-server `select` awaits
  `detachActive()` on the previous slot before `switchToSession` on the new one.
  `BoundedWait` is a one-shot continuation, not a task group: a task group waits
  for its stragglers, which hung the suite. Every selection path (`select`,
  `createSession`, `applyPendingSelection`, both deep-link attach paths) bumps
  `selectionGeneration` and bails after any `await` that finds a newer one;
  `selectionsInFlight` keeps `reconcileSelection` out of the way meanwhile. The
  coordinator side is `attachEpoch` (bumped by `detachActive()`, which also
  cancels the F3 launch restore): `switchToSession`/`createNewSession`/
  `attachRemoteSession` undo and stay silent when it moved under them.
- **The hub mirrors the coordinator, never the reverse.** `reconcileSelection`
  (from `slotDidChange`) adopts `slot.activeSessionId` into `activeRef` when no
  selection is in flight — ⌘W, terminate, steal, failed resume, Attach sheet, QR.
  `mirror(_:serverId:)` does the same right after an attach returns.
- **Offline servers keep cached rows** (`ServerSection.isCached`); so do
  disabled ones (spec §7), but those are not selectable and `orderedRefs` skips
  them. Selecting a cached row stores the single `pendingRef` (== `activeRef`;
  the next selection replaces it, so an abandoned choice never attaches later),
  triggers that server's recovery, and applies when a live list proves the
  session still exists. A row whose server has no coordinator and is not
  building one (disabled, token-less) is refused with a notice before any
  state moves — it used to detach the live session and then do nothing.
- **Concurrent start and fan-out.** `start()` builds every enabled slot in a
  task group, each after its own stagger; `buildSlot` re-checks `isWanted`
  (started + still enabled) after the handshake, so `stop()` or a disable that
  raced the build tears the fresh coordinator down instead of leaving it
  connected. `handleForegroundTransition` fans out the same way; the macOS
  `SessionCoordinator.start()` registers no observers of its own.
- **Deep links wait for the first `start()` to complete** (`startCompleted`,
  drained in a `defer`) — never on `slots.isEmpty`, which hung forever when
  every enabled bookmark was token-less.
- **Push.** `syncPushRegistration` remembers the settings; slots built later get
  them after their handshake. Disabling or removing a server unregisters on it
  (bounded) before `tearDown()`.
- **Management.** `reloadBookmarks` turns a bookmark saved enabled past the cap
  of 8 back off with a notice (add/pair save enabled). `rebuildSlot` replaces a
  coordinator after an edit that may have changed the token. The Mac/iOS edit
  forms mutate the existing `ConnectionConfig` so `enabled`/`instanceId`/
  `displayName` survive an edit. `focusCoordinator`/`focusServerId` (active,
  else the only enabled, else the first live) drive the single-server
  surfaces when nothing is selected (G8).
- `ConnectionConfig` decodes its three optional multi-server fields leniently:
  the store decodes the list all-or-nothing, so one wrong-typed field would
  otherwise wipe every bookmark.
- `maxEnabled` is 8; `setEnabled` refuses the ninth with a `notice`.
- Deep links (`SessionDeepLink`, scheme `coderelay`, legacy `clauderelay`,
  optional `?server=<instanceId>`) route: instance id → unique live session →
  single server's remote attach → `.notFound`.
- `HubMigration` runs once per install (`HubStateStore.isMigrated`): the
  previously last-used bookmark keeps `enabled = true`, the legacy
  single-namespace ownership keys move under it, the rest are disabled.
- `ServerStatusChecker` polls only **disabled** bookmarks; for enabled ones the
  live connection is the status (`ServerSectionStatus.derive`).
- `SharedSessionCoordinator.connectionState` is `@Published`, mirrored from
  `connection.$state`; a computed property fired no `objectWillChange`, so
  without a subclass mirror (iOS) the hub never saw a dropped socket.
- **Session loss notices** (`SessionLoss.swift`, `SessionLossCollector.swift`; spec
  `docs/superpowers/specs/2026-10-31-session-takeover-notices-design.md`). Slots
  report taken-over/ended sessions to the hub's `SessionLossCollector`: dedupe per
  batch, 120 s repeat suppression, 1 s live debounce, holds nest with an epoch.
  A fan-out (`start`, foreground) holds the collector until every slot's
  `awaitPassFinished()` returns or 10 s pass, so N servers yield one aggregated
  alert; the fan-out never blocks its caller, and `stop()` resets the collector.
  The coordinator's `SessionOwnershipStore` baseline is diff-only (token-stamped,
  `.enable` is silent). The alert is `sessionLossAlert(_:isTopmost:onOK:)` on the root
  and every sheet, enabled on the topmost presenter only; its binding setter
  ignores `false`, so only OK (`dismissTakenAlert()`) clears an unread alert; a batch arriving while it is up merges into it (deduped by server + session, names in sidebar order).

## Session loading sheet (`Views/SessionLoadingPresentation.swift`, `SessionLoadingSheet.swift`)

- `SessionLoadingPresentation(loadPhase:isRecovering:recoveryPhase:sessionName:serverName:)`
  is the one rule for what the sheet says: title "Loading session" / "Reconnecting",
  the phase label as status, the byte counter as `detail` (a literal "0 KB" from
  the first active phase so the layout never jumps), "session · server", Cancel only
  while recovering. `expectsSession: false` keeps the handshake phases
  (connecting / authenticating / loadingSessions) from raising a modal when no
  session is attached or pending — a bare launch against an unreachable host
  would otherwise show an uncancellable sheet for ~54 s.
- `SessionLoadingSheetModel.update(_:)` presents immediately, holds at least
  `minimumVisible` (600 ms) and dismisses when nothing is loading; `shown` keeps the
  last text while the sheet animates down. A presentation unchanged for
  `stallTimeout` (15 s) lowers the sheet until it changes again — the one place
  "the sheet never stays up" is enforced. When a load ends with a session
  attached and nothing failed (`endsInReady`: `lastLoadFailed`/pending error
  alerts false, and a reconnect not cancelled), `showReady()` swaps in a
  "Ready" presentation (`readied()`: final bytes, checkmark, no Cancel) for
  `readyDwell` (0.6 s) before dismissing; a new load during Ready takes over.
  `SharedSessionCoordinator.lastLoadFailed` is set BEFORE the phase clears on
  every failure path — `switchToSession`'s rollback awaits a resume before its
  error, so ordering on the error flags alone would flash Ready. The terminal blackout
  (`View.terminalLoadingCover(_:)`) follows `isPresented` so both lift together.
  Host the sheet on the view that owns the model, never on a child keyed by
  coordinator identity.
- Producers: `switchToSession` publishes `.attaching` on EVERY switch (also with a
  cached terminal), `reloadTerminalFromServer` publishes it before its RPC and
  clears it in its `catch`; the replay hooks clear it on the first visible frame.
  `TerminalReloadFade.reload(coordinator:id:)` is the session-name tap.

