# Session takeover notices — design

Date: 2026-10-31. Applies to every client: iOS, macOS (Swift, `CodeRelayClient`)
and Android, Linux (Kotlin, `core-session` + `feature-workspace`, shared sources).
One server and protocol change, permitted by §4b: protocol v4 adds the server push
`session_ended {sessionId, reason}`, sent only to clients that authenticate with v4 or later.

## Intent

Only one device holds a session at a time. When device B attaches a session
device A was holding, A must find out — immediately if A is in the foreground,
and the moment A comes back if it was in the background, suspended or killed.
Today A often finds out wrongly or not at all:

1. A wake pass announces only the **first** lost session
   (`SessionHandshake.firstLostSession`, Swift and Kotlin); the rest vanish
   silently. A test locks this in (`SessionHandshakeTest.kt` ~417).
2. The alert is one name + one flag per coordinator
   (`ActivityCoordinator.presentStolenAlert` / Kotlin `_stolenAlert`), so a
   second steal overwrites the first.
3. A `session_stolen` push queued on the socket during the server's 60 s read-idle
   window can be delivered on resume at the same time the wake diff runs; both
   raise the alert for the same session.
4. The alert is hosted only on `hub.focusCoordinator` (iOS `WorkspaceView`,
   macOS `MainWindow`, Kotlin `HubWorkspaceScreen`/`WorkspacePane`). A steal on a
   non-focused server is invisible until the user switches to it, and stealing
   the *active* session moves focus away so its alert can be lost.
5. Anything missing from the token-scoped list is called "attached from another
   device", including sessions that exited, expired, or died with a server
   restart.
6. A cold launch (iOS routinely kills backgrounded apps) is silent by design, so
   the commonest "I came back and sessions are gone" case says nothing.

## What the user sees (decided by the user)

- **Foreground, live:** the session leaves the sidebar and tab bar at once and a
  modal alert appears.
- **Returning from background, or cold launch after the app was killed:** every
  enabled server's list is refreshed; every session this device held that was
  taken elsewhere is reported — **in one alert**, never one per session and never
  the same session twice.
- **Cold launch announces too** (reverses the old "launch is silent" rule). The
  "before" set is the per-server persisted session list (see Mechanism §3).
- **Sessions that ended get their own, quieter message**, distinct from "taken".

### Copy

Taken (modal alert, OK only; title "Session Moved", or "Sessions Moved" for 2+):

- 1: `Renly was attached from another device.`
- 2: `Renly and Stannis were attached from another device.`
- 3+: `Renly, Stannis and 2 others were attached from another device.`
  (first two by sidebar order, then the count.)

Ended (non-modal: the hub's existing notice pill, not an alert):

- 1: `Renly ended while you were away.`
- 2: `Renly and Stannis ended while you were away.`
- 3+: `Renly, Stannis and 2 others ended while you were away.`

When one notice covers sessions from more than one server, each name is
followed by ` (on <server display name>)`. With one server, no suffix.

A batch can produce both: one taken alert and one ended pill.

## Goals / non-goals / anti-goals

Goals: the behaviour above, identically on all four apps, with the decision
logic in pure, unit-tested functions.

Non-goals:
- Push notification to a backgrounded device at steal time (possible later; the
  server's push pipeline could carry it).
- Detecting a steal between two devices sharing **one** token. Ownership is per
  token; paired devices each get their own token. Same-token displacement keeps
  the session in our list, so no diff can see it. Out of scope.
- Any change to how the sidebar, alerts, or the notice pill look.

Anti-goals (a failure even if it "works"):
- The same session announced twice (live push + wake diff, or two passes).
- A session the user closed **on this device** announced as taken or ended.
- Any notice on the very first launch after install or after pairing a server
  (there is no "before").
- A notice that blocks or delays the session list refresh itself.

## Mechanism

### 1. Lost-session classification (pure)

A shared pure function, Swift and Kotlin:

```
classify(before: [(id, name)], owned: [SessionInfo], all: [SessionInfo]?, myTokenId)
  -> (taken: [(id, name)], ended: [(id, name)])
```

- `lost` = ids in `before` that are not **non-terminal** in `owned`. (The
  token-scoped list keeps terminal sessions — `listSessionsForToken` does not
  filter them — so "absent" alone misses sessions that ended.)
- For each lost id: **taken** if `all` contains it, non-terminal, with
  `tokenId != myTokenId`; otherwise **ended**.
- Preserves `before` order (sidebar order) so copy is deterministic.
- If `all` is nil (the extra RPC failed), every lost session is **taken** —
  the pre-existing behaviour. (Builder's call recorded below.)

`all` comes from `SessionController.listAllSessions()` (`session_list_all`),
issued **only when `lost` is non-empty**, inside the handshake after the
token-scoped list, so the common case costs no extra round trip. `myTokenId` is
the token id from `auth_success`.

### 2. Hub-level collector (replaces per-coordinator alert state)

`ServerHub` (Swift and Kotlin) gains a `TakenElsewhereCollector`:

- `report(serverId, sessionId, name, kind: taken|ended)` — dedupes by
  `SessionRef` within a batch.
- Remembers announced `SessionRef`s for 2 minutes and drops repeat reports, so a
  late queued `session_stolen` after a wake diff (or vice versa) is silent.
- **Flush rules:**
  - During a hub fan-out (`start()` and `handleForegroundTransition`), hold until
    every slot's pass has finished, capped at 10 s so one dead server cannot
    hold everyone's notice; reports arriving after the cap form the next batch.
  - Outside a fan-out (live pushes), flush 1 s after the last report, so two
    steals in quick succession produce one alert.
- Exposes the pending taken alert and ended notice as published state the
  workspace root observes.

Coordinators stop presenting anything themselves. They report through one new
additive hook on `ServerSlotCoordinating` (same pattern as the existing four),
e.g. `onSessionsLost`. `ActivityCoordinator`'s stolen-alert fields and
`presentStolenAlert` are removed (Swift and Kotlin), along with every
per-coordinator "Session Moved" alert binding.

### 3. Where the diff runs, and its baseline

**Every authoritative list application diffs — not only the handshake.**
`reconcile(tokenScoped:)` (Swift, 8 call sites) and `applyServerSessions`
(Kotlin) are where the pane is rebuilt, and today they drop a missing session
silently; once a plain `fetchSessions` has dropped it, the next handshake's
"before" no longer contains it and it is never announced. Kotlin's
`RecoveryController` ends with a bare `fetchSessions()` in three places (~:321,
:327, :470), so on Android/Linux this is the normal path, not an edge case. The
diff therefore lives at the single point where a list is applied: that function
computes `lost` against the baseline below, and the caller (handshake or
fetch) issues the conditional `listAllSessions()`, classifies, and reports.
Kotlin's recovery tail need not change to a handshake for correctness.

**Baseline = a persisted per-server id set of non-terminal sessions as of the
last render.** A new small structure in each server's `SessionOwnershipStore`
(namespaced by `ownershipKeyPrefix`), holding `(id, name)` for exactly the
non-terminal sessions currently rendered. It is rewritten on every list
application and on every local removal (terminate, close, stolen clean-up, live
end — §4b). The names map cannot serve: it omits unnamed sessions and keeps
terminal ones, which would re-announce "ended" on every launch until the server
reaps the session.

This is a **diff baseline only**. It never populates the pane — the server's
token-scoped list stays the sole source for that, so the rule in
`SessionOwnershipStore`'s header ("ownership is not persisted; a persisted set
blanked the pane") still holds for rendering. The first launch after upgrading
finds no baseline and stays silent; that is acceptable.

The baseline is stamped with the token id it was recorded under. If the slot
authenticates with a different token id (bookmark edited, re-paired), the
baseline is discarded without announcing — otherwise every old session would
classify as "taken" by the new token's own device.

### 3b. Which passes announce

- **Announce:** app launch (iOS/Android/Linux process start; macOS app launch
  and a `MainWindow` hub re-created while the app kept running), foreground,
  wake, network restored, recovery, and every live refresh.
- **Silent (baseline reset only):** building a slot because the user just
  enabled a server, `rebuildSlot` after a bookmark edit, or a token change.
  Enabling a server that was off for days must not open with a list of old
  losses. Implemented as a third handshake reason (e.g. `.enable`) or an
  equivalent flag on slot build.

### 4. Live path — taken

`handleSessionStolen` keeps its clean-up (drop row, evict terminal, forced
refetch) and reports `taken` to the hub instead of raising the alert. It does
not need classification: the server only sends `session_stolen` for a takeover.
Its guard (`sessions.contains || activeSessionId == id`) stays; with the diff in
every list application (§3) a push that arrives after a refresh already dropped
the row has already been reported, and the collector's repeat suppression
covers the reverse order.

### 4b. Live path — ended while the app is open

Today the clients ignore live termination (`session_terminated` /
`session_expired` and any state transition to terminal): a session that exits
while the user watches stays in the pane until the next refresh, and the new
diff would then call it "ended while you were away". So:

- A session that ends while the app is connected is removed from the pane and
  the baseline **at once and silently** — no pill (the user was there).
- It is added to the collector's announced set, so no later diff reports it.
- The builder must establish which server message reaches a connected but
  non-attached client when one of its sessions ends (`session_terminated` goes
  to the attached connection; state/activity observers may carry the terminal
  state for the rest) and handle each. If none reaches a non-attached client, a
  minimal server-side addition to notify the owning token's observers is in
  scope.

### 5. Presentation

One taken alert and one ended notice, hosted at the workspace root and bound to
the hub — iOS `WorkspaceView`, macOS `MainWindow`, Kotlin `WorkspaceScreen(hub)`
— never on a per-coordinator child (which is re-keyed on a cross-server switch).
On iPhone it must coexist with the sidebar sheet and loading sheet the way the
other root-level presentations already do (one sheet per presenter).

### 6. Every server, every return — and the fan-out hold

Each foreground/wake/network event must end with every enabled server's list
applied (and therefore diffed, §3). Because the diff lives in list application,
a dropped trigger is harmless as long as the pass already in flight ends in a
list application — which handshakes and recoveries do on both platforms.

The fan-out hold (§2) must wait for that in-flight pass, not just for the
trigger call to return: `handleForegroundTransition` returns immediately when a
handshake or recovery is already running (`canStartForegroundPass`,
`foregroundInFlight`, Kotlin `isHandshakeInFlight` / `_isRecovering`), which is
exactly the launch case where launch, `scenePhase` and network-restored fire
within ~100 ms. So each slot exposes a "pass finished" signal — awaiting its
in-flight handshake/recovery if one is running — as a second additive
`ServerSlotCoordinating` hook alongside `onSessionsLost`; the 10 s cap still
bounds it.

## Tests

Swift (`Tests/CodeRelayClientTests`) and Kotlin (`core-session` tests), mirrored:

- `classify`: taken vs ended vs not lost; terminal-in-owned counts as ended;
  `all == nil` fallback; order preserved.
- Copy formatter: 1 / 2 / 3+ names, single vs multi-server suffix, title
  singular/plural.
- Collector: batch dedupe; 2-minute repeat suppression; fan-out hold and 10 s
  cap; 1 s live debounce — with an injected clock.
- Handshake: wake reports all lost sessions (replace the single-session test);
  launch reports from the persisted baseline; first launch with no baseline
  reports nothing; `listAllSessions` is called only when something is lost.
- List application: a plain `fetchSessions` that drops a session reports it
  (Swift `reconcile`, Kotlin `applyServerSessions`); a session removed locally
  is never reported.
- Baseline: rewritten on every application and local removal; holds only
  non-terminal sessions; discarded silently on token change; a session that
  ended and was announced is not announced on the next launch.
- Live end: a terminated session leaves the pane at once, silently, and a later
  diff does not report it.
- Silent reasons: enabling a server and rebuilding a slot announce nothing.
- Hub: a steal on a non-focused server surfaces; stealing the active session
  surfaces even though focus moves; the fan-out hold waits for a slot whose
  trigger was dropped because a pass was already in flight.

## Decided by the builder (my calls, open to override)

- 2-minute repeat-suppression window, 10 s fan-out cap, 1 s live debounce.
- Ended notices use the existing hub notice pill.
- Fallback when `session_list_all` fails: call everything "taken".
- Multi-server suffix only when a single notice spans more than one server.
- 3+ names: first two, then "and N others".
- The diff runs in every list application, not only the handshake (§3).
- A persisted per-server baseline id set, used only for diffing, stamped with
  the token id; first launch after upgrade is silent (§3).
- Enabling a server or rebuilding a slot is silent (§3b).
- Sessions that end while the app is open leave the pane silently (§4b).
- Each slot exposes a "pass finished" signal for the fan-out hold (§6).
