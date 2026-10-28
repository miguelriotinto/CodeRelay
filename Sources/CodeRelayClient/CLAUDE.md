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
  for its stragglers, which hung the suite.
- **Offline servers keep cached rows** (`ServerSection.isCached`). Selecting one
  stores a pending selection, triggers that server's recovery, and applies the
  selection when a live list proves the session still exists.
- **Fan-out, not per-coordinator observers.** Foreground/wake/network events go
  through `handleForegroundTransition`, staggered 150 ms per server; the macOS
  `SessionCoordinator.start()` registers nothing of its own.
- `maxEnabled` is 8; `setEnabled` refuses the ninth with a `notice`.
- Deep links (`SessionDeepLink`, scheme `coderelay`, legacy `clauderelay`,
  optional `?server=<instanceId>`) route: instance id → unique live session →
  single server's remote attach → `.notFound`.
- `HubMigration` runs once per install (`HubStateStore.isMigrated`): the
  previously last-used bookmark keeps `enabled = true`, the legacy
  single-namespace ownership keys move under it, the rest are disabled.
- `ServerStatusChecker` polls only **disabled** bookmarks; for enabled ones the
  live connection is the status (`ServerSectionStatus.derive`).
