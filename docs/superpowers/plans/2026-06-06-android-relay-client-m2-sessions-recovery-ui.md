# Android Relay Client — M2: Sessions, Recovery & Adaptive UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. **Depends on M1.**

**Goal:** Full session management + recovery parity with iOS (no speech): the recovery circuit-breaker state machine, multi-session tabs/sidebar, ownership/activity tracking, QR share+scan, deep links, the adaptive phone/tablet Compose UI, and all settings (14 `@AppStorage` keys + 1 Keychain token = 15 persisted prefs).

> **⚠️ Read `docs/superpowers/plans/2026-06-08-android-relay-client-corrections.md` first.** M2-relevant corrections: settings count is **14 (+1 Keychain) = 15**, not 18 (A2); `SessionNaming.pickDefaultName` is **random** + explicit `fallbackIndex` (A3, fixed in Task 1); the four coordinator ops are **distinct sequences** with switch-only eager wiring (A5 — see Task 6 callout); **RecoveryController is a rewrite, not a transcription** — 5 s probe, auth/resume-failure-is-terminal, 3 s cooldown, healthy-ping breaker reset, cancel-suspends-breaker, 1 s cancel-debounce, send-suppression, defer `isRecovering` past the probe (A4 — see Task 3 callout); ownership key segment is `ownedSessions` (B5, fixed); TerminalCache needs `pruneStale/cachedIds/removeAll` (B2).

**Architecture:** Add `:core-session` (coordinator + RecoveryController + ActivityCoordinator + AuthCoordinator + LRU-8 terminal cache + ownership store), extend `:core-storage`, build the `:feature-servers`/`:feature-workspace`/`:feature-settings` Compose modules, and replace the M1 demo with the real navigation graph in `:app`.

**Swift source of truth:**
- `Sources/ClaudeRelayClient/ViewModels/SharedSessionCoordinator.swift`, `RecoveryController.swift`, `ActivityCoordinator.swift`, `TerminalCache.swift`, `ServerStatusChecker.swift`
- `Sources/ClaudeRelayClient/AuthCoordinator.swift`
- `Sources/ClaudeRelayClient/Helpers/SessionOwnershipStore.swift`, `SessionNaming.swift`, `NetworkMonitor.swift`
- `ClaudeRelayApp/Views/*` and `ClaudeRelayApp/Models/AppSettings.swift`

> **Before starting M2, read the listed Swift files.** The plans below give faithful Kotlin ports of the load-bearing logic (recovery generation/guards, LRU cache, ownership diff-writes, naming themes) with full code, and specify Compose UI at the task level with manual-verification steps (UI cannot be meaningfully unit-tested).

---

## File Structure (added in M2)

```
core-session/src/main/kotlin/relay/session/
├── SessionCoordinator.kt        # port of SharedSessionCoordinator (StateFlow-based)
├── RecoveryController.kt        # circuit breaker, generation guards, backoff
├── ActivityCoordinator.kt       # agent map, awaiting-input, stolen flags
├── AuthCoordinator.kt           # single-flight auth + withAuth retry-once
├── TerminalCache.kt             # LRU-8 of TerminalSessionVm + native views
├── ServerStatusChecker.kt       # 15s bookmark health poll
├── NetworkObserver.kt           # ConnectivityManager.NetworkCallback wrapper
└── RecoveryPhase.kt             # enum reconnecting/authenticating/resuming
core-storage/src/main/kotlin/relay/storage/
├── SessionOwnershipStore.kt     # names / owned (device-scoped) / agents, diff-write
└── SessionNaming.kt             # theme name pools
feature-servers/.../             # ServersScreen, AddEditServerSheet, server VM
feature-workspace/.../           # WorkspaceScreen (adaptive), SessionSidebar, tabs, terminal host, QR
feature-settings/.../            # SettingsScreen + AppSettings (DataStore)
app/.../                         # RelayNavGraph, deep-link intent handling
```

---

## Task 1: `SessionOwnershipStore` (diff-checked, device-scoped) + `SessionNaming`

**Files:**
- Create: `core-storage/src/main/kotlin/relay/storage/SessionOwnershipStore.kt`
- Create: `core-storage/src/main/kotlin/relay/storage/SessionNaming.kt`
- Test: `core-storage/src/test/kotlin/relay/storage/SessionNamingTest.kt` (JVM)
- Test: `core-storage/src/androidTest/kotlin/relay/storage/SessionOwnershipStoreTest.kt`

> Port of `SessionOwnershipStore.swift` (three maps; **owned IDs keyed by device id**; **diff-checked writes** — only persist on change) and `SessionNaming.swift` (theme name pools, exclude-used, "Session N" fallback).

- [ ] **Step 1: Write the failing naming test (pure JVM)**

```kotlin
package relay.storage

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import relay.protocol.SessionNamingTheme

class SessionNamingTest {
    @Test fun `picks unused name from theme`() {
        val used = setOf("Jon Snow")
        // Signature mirrors Swift pickDefaultName(usedNames, theme, fallbackIndex)
        val name = SessionNaming.pickDefaultName(used, SessionNamingTheme.GAME_OF_THRONES, fallbackIndex = 1)
        assertFalse(name in used); assertTrue(name.isNotBlank())
        assertTrue(name in SessionNamingTheme.GAME_OF_THRONES.names)  // a real pool name, randomly chosen
    }
    @Test fun `falls back to Session fallbackIndex when pool exhausted`() {
        val pool = SessionNamingTheme.VIKING.names.toSet()
        val name = SessionNaming.pickDefaultName(pool, SessionNamingTheme.VIKING, fallbackIndex = 7)
        assertEquals("Session 7", name)   // exact: "Session $fallbackIndex", NOT used.size+1
    }
}
```

- [ ] **Step 2: Run to verify it fails / Step 3: implement**

`SessionNaming.kt` — port the theme pools from `SessionNaming.swift:42-144` **verbatim** (Game of Thrones, Viking, Star Wars, Dune, LOTR, Star Trek; ≈70 names each). Add `SessionNamingTheme` enum to `:core-protocol` with the iOS **camelCase** raw values pinned via `@SerialName` (`gameOfThrones, viking, starWars, dune, lordOfTheRings, starTrek`; default `gameOfThrones`) so persisted `@AppStorage` values round-trip. **Port the full Swift signature** (`SessionNaming.swift:157-164`):

```kotlin
fun pickDefaultName(usedNames: Set<String>, theme: SessionNamingTheme, fallbackIndex: Int): String {
    val available = theme.names.filter { it !in usedNames }
    return available.randomElement() ?: "Session $fallbackIndex"   // RANDOM, not first-unused
}
```

> Do NOT use `pick(theme, used)` returning the "first unused" entry, and do NOT compute the fallback as `"Session ${used.size + 1}"` — iOS picks a **random** unused name and takes an explicit caller-supplied `fallbackIndex`. The lossy shape diverges from iOS UX and numbering. (`randomElement()` on a Kotlin `List` is the analog of Swift `Array.randomElement()`.)

`SessionOwnershipStore.kt` (Android, DataStore/SharedPreferences):

```kotlin
package relay.storage

import android.content.Context
import java.util.UUID

/** Port of SessionOwnershipStore.swift. ownedSessionIds keyed by device id;
 *  writes are diff-checked (skip when unchanged) to avoid churn. */
class SessionOwnershipStore(context: Context, private val deviceId: String) {
    private val prefs = context.getSharedPreferences("relay.ownership", Context.MODE_PRIVATE)
    // Key strings mirror the iOS source segments (SessionOwnershipStore.swift):
    // sessionNames / ownedSessions(.deviceId) / agentSessions. Note the owned key
    // segment is "ownedSessions", NOT "ownedSessionIds". (Exact cross-platform key
    // parity is a non-goal — Android shares no UserDefaults with iOS — but matching
    // the source segment avoids confusion and eases any future shared-store work.)
    private val namesKey = "sessionNames"               // plain
    private val ownedKey = "ownedSessions.$deviceId"    // device-scoped
    private val agentsKey = "agentSessions"             // plain

    private var namesCache: MutableMap<UUID, String> = load(namesKey)
    private var ownedCache: MutableSet<UUID> = loadSet(ownedKey)
    private var agentsCache: MutableMap<UUID, String> = load(agentsKey)

    val names: Map<UUID, String> get() = namesCache
    val owned: Set<UUID> get() = ownedCache
    val agents: Map<UUID, String> get() = agentsCache

    fun setName(id: UUID, name: String?) {
        val changed = if (name == null) namesCache.remove(id) != null
                      else namesCache.put(id, name) != name
        if (changed) persist(namesKey, namesCache)
    }
    fun claim(id: UUID) { if (ownedCache.add(id)) persistSet(ownedKey, ownedCache) }
    fun unclaim(id: UUID) { if (ownedCache.remove(id)) persistSet(ownedKey, ownedCache) }
    fun setAgent(id: UUID, agentId: String?) {
        val changed = if (agentId == null) agentsCache.remove(id) != null
                      else agentsCache.put(id, agentId) != agentId
        if (changed) persist(agentsKey, agentsCache)   // small set; persist on change
    }

    // (de)serialize maps/sets as simple delimited strings or JSON; impl detail.
    private fun load(key: String): MutableMap<UUID, String> = TODO("parse stored map")
    private fun loadSet(key: String): MutableSet<UUID> = TODO("parse stored set")
    private fun persist(key: String, map: Map<UUID, String>) = TODO("write map")
    private fun persistSet(key: String, set: Set<UUID>) = TODO("write set")
}
```

> The `TODO`s are trivial serialization (use `WireJson` map/set encoding) — fill at execution with a 5-line JSON encode/decode each. The load-bearing logic (diff-check, device-scoped key) is fully specified above.

- [ ] **Step 4: instrumented test** asserts claim/unclaim/setName persist and survive a new store instance; diff-check verified by asserting no write when value unchanged (spy on prefs).

- [ ] **Step 5: Commit** `feat(storage): ownership store (device-scoped, diff-checked) + naming themes`

---

## Task 2: `TerminalCache` (LRU-8, never evict active)

**Files:**
- Create: `core-session/src/main/kotlin/relay/session/TerminalCache.kt`
- Test: `core-session/src/test/kotlin/relay/session/TerminalCacheTest.kt` (JVM)

> Port of `TerminalCache.swift`: LRU bound 8; `touch(id)`; `enforceLimit(activeSessionId)` evicts LRU victim **unless** it is the active session (active may temporarily push to 9).

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.session

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import java.util.UUID

class TerminalCacheTest {
    @Test fun `evicts LRU beyond 8 but never the active`() {
        val cache = TerminalCache<String>(limit = 8)
        val ids = List(9) { UUID.randomUUID() }
        ids.forEach { cache.put(it, "vm-$it"); cache.touch(it) }
        val active = ids.last()
        cache.enforceLimit(active)
        assertEquals(8, cache.size)
        assertNotNull(cache[active])
        assertNull(cache[ids.first()])   // oldest evicted
    }
    @Test fun `active session survives even at limit+1`() {
        val cache = TerminalCache<String>(limit = 2)
        val a = UUID.randomUUID(); val b = UUID.randomUUID(); val c = UUID.randomUUID()
        listOf(a,b,c).forEach { cache.put(it, "x"); cache.touch(it) }
        cache.enforceLimit(a)            // a is active but oldest
        assertNotNull(cache[a])          // not evicted because active
    }
}
```

- [ ] **Step 2–4: implement + pass**

```kotlin
package relay.session

import java.util.UUID

class TerminalCache<T>(private val limit: Int = 8) {
    private val map = LinkedHashMap<UUID, T>(16, 0.75f, true) // access-order
    val size get() = map.size
    operator fun get(id: UUID): T? = map[id]
    fun put(id: UUID, value: T) { map[id] = value }
    fun touch(id: UUID) { map[id] }                         // access-order bump
    fun remove(id: UUID): T? = map.remove(id)
    fun enforceLimit(activeSessionId: UUID?) {
        while (map.size > limit) {
            val victim = map.keys.firstOrNull { it != activeSessionId } ?: break
            map.remove(victim)
        }
    }

    // Required by SharedSessionCoordinator (corrections §B2): fetchSessions evicts
    // cached terminals for sessions gone from the server; teardown clears all.
    val cachedIds: Set<UUID> get() = map.keys.toSet()
    val count: Int get() = map.size
    fun removeAll() = map.clear()
    /** Evict any cached terminal whose id is not in the server's current set. */
    fun pruneStale(knownSessionIds: Set<UUID>): List<UUID> {
        val stale = map.keys.filter { it !in knownSessionIds }
        stale.forEach { map.remove(it) }
        return stale
    }
}
```

> **Note:** Swift's `enforceLimit` keys off the cached-view count + an explicit `lru` array
> rather than `LinkedHashMap` access-order. The access-order map above is an acceptable
> idiomatic Kotlin equivalent **provided** `touch()` actually bumps order (calling
> `map[id]` on an access-order `LinkedHashMap` does) and the stale-prune methods above exist
> — the coordinator's `fetchSessions` (`SharedSessionCoordinator.swift:349-355`) and teardown
> (`:720`) depend on them.

- [ ] **Step 5: Commit** `feat(session): LRU-8 terminal cache`

---

## Task 3: `RecoveryController` — circuit breaker + generation guards + backoff

**Files:**
- Create: `core-session/src/main/kotlin/relay/session/RecoveryPhase.kt`
- Create: `core-session/src/main/kotlin/relay/session/RecoveryController.kt`
- Test: `core-session/src/test/kotlin/relay/session/RecoveryControllerTest.kt`

> The most behaviorally critical port. From `RecoveryController.swift`: `recoveryGeneration` captured at entry & rechecked at every await; **two distinct guards** (`isRecoveryDispatched` sync entry-lock vs `isRecovering` UI flag); `isAlive()` short-circuit; **3 auto-failures → `autoRecoverySuspended`**, reset only by user signals; backoff `[0,1,2,4,8,15]`s; defer-idempotency clears flags even on cancel.
>
> **⚠️ Treat this as a REWRITE from source, not a transcription of the skeleton below.** The reference Kotlin in Step 3 is a starting shape that is missing nine load-bearing behaviors verified against `RecoveryController.swift` (corrections §A4). Before implementing, re-read the Swift file and wire in ALL of:
> 1. **5 s probe timeout** (not ~2 s) — `isAlive` wraps a 5 s pong wait (`RelayConnection.swift:313`).
> 2. **Auth/resume failure is TERMINAL** — a successful reconnect whose `restoreSession` (auth/resume) fails counts **one** breaker failure and returns; it does NOT re-loop the 6-step backoff. Only *reconnect* failures retry the backoff (`RecoveryController.swift:202-206,272`).
> 3. **App-level vs transport-level restore-error split** — an app-level error (session gone) sets `sessionAttachFailed`, does NOT set `connectionTimedOut`, but still counts toward the breaker (`:258-272`).
> 4. **3 s auto-recovery cooldown** — `scheduleAutoRecovery` drops auto-recoveries within 3 s of the last one ending (`:43,94-98`); stamp `lastRecoveryEndedAt = now` in the `finally` (inject a monotonic clock — do NOT stamp `0L`).
> 5. **`resetAutoRecoveryBreaker()` on healthy ping** — a successful keepalive ping clears the breaker (`:69-74`, wired to `onHealthyPing`). A 4th reset trigger beyond user signals.
> 6. **`cancel()`** sets `autoRecoverySuspended = true` + `recoveryFailed = true` + stamps `lastCancelledAt` + bumps generation (`:286-299`).
> 7. **1 s cancel-debounce** on `triggerUserRecovery` (`:56-58,124-127`) to avoid sheet-dismiss → ON_RESUME re-trigger loops.
> 8. **`suppressAllViewModelSends(true/false)`** toggled around the recovery body (`:165,168`) — inject a `suppressSends(Boolean)` lambda.
> 9. **`isRecovering = true` only AFTER the `isAlive()` false branch** (`:164`) — the alive short-circuit must not flash recovery UI.
>
> Extend the test suite (Step 1) to cover: cooldown drop, healthy-ping breaker reset, cancel-suspends-breaker, cancel-debounce, and "reconnect-success-then-auth-fail is terminal (counts once, no re-loop)."

- [ ] **Step 1: Write the failing tests (inject a fake clock + fake connection)**

```kotlin
package relay.session

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class RecoveryControllerTest {
    @Test fun `alive short-circuit skips backoff and fetches`() = runTest {
        val env = RecoveryTestEnv(alive = true)
        env.controller.triggerUserRecovery()
        assertEquals(0, env.backoffSleeps)        // never slept
        assertTrue(env.fetchedSessions)
        assertFalse(env.controller.isRecovering.value)
    }
    @Test fun `three auto failures suspend the breaker`() = runTest {
        val env = RecoveryTestEnv(alive = false, reconnectSucceeds = false)
        repeat(3) { env.controller.scheduleAutoRecovery() }
        assertTrue(env.controller.autoRecoverySuspended)
        env.backoffSleeps = 0
        env.controller.scheduleAutoRecovery()     // suspended -> no work
        assertEquals(0, env.backoffSleeps)
    }
    @Test fun `user recovery resets the breaker`() = runTest {
        val env = RecoveryTestEnv(alive = true)
        repeat(3) { env.controller.scheduleAutoRecovery() }
        env.controller.triggerUserRecovery()
        assertFalse(env.controller.autoRecoverySuspended)
    }
    @Test fun `newer generation makes older recovery bail`() = runTest {
        val env = RecoveryTestEnv(alive = false, reconnectSucceeds = true, slowReconnect = true)
        val first = env.launchRecovery()
        env.controller.triggerUserRecovery()       // bumps generation
        first.join()
        assertEquals(1, env.restoredCount)          // only the newest restored
    }
    @Test fun `cancel mid-backoff still clears isRecovering`() = runTest {
        val env = RecoveryTestEnv(alive = false, reconnectSucceeds = true, slowReconnect = true)
        val job = env.launchRecovery()
        job.cancelAndJoin()
        assertFalse(env.controller.isRecovering.value)
    }
}
```

(`RecoveryTestEnv` provides a `RecoveryController` with injected lambdas: `isAlive`, `reconnect`, `reauth`, `resumeActive`, `fetchSessions`, and a fake `sleep` counting `backoffSleeps`. Define it in the test file.)

- [ ] **Step 2: Run to verify it fails / Step 3: implement**

`RecoveryPhase.kt`:

```kotlin
package relay.session
enum class RecoveryPhase { RECONNECTING, AUTHENTICATING, RESUMING }
```

`RecoveryController.kt` (faithful port; collaborators injected so it's testable without Android):

```kotlin
package relay.session

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class RecoveryController(
    private val scope: CoroutineScope,
    private val isAlive: suspend () -> Boolean,
    private val reconnect: suspend () -> Unit,
    private val reauth: suspend () -> Unit,
    private val resumeActive: suspend () -> Unit,
    private val fetchSessions: suspend () -> Unit,
    private val sleepMs: suspend (Long) -> Unit = { delay(it) },
) {
    private val backoffMs = longArrayOf(0, 1000, 2000, 4000, 8000, 15000)

    private val _isRecovering = MutableStateFlow(false)
    val isRecovering: StateFlow<Boolean> = _isRecovering
    private val _phase = MutableStateFlow<RecoveryPhase?>(null)
    val phase: StateFlow<RecoveryPhase?> = _phase
    private val _connectionTimedOut = MutableStateFlow(false)
    val connectionTimedOut: StateFlow<Boolean> = _connectionTimedOut

    @Volatile var autoRecoverySuspended = false; private set
    private var consecutiveAutoFailures = 0
    private var lastRecoveryEndedAt = 0L
    @Volatile private var recoveryGeneration = 0L
    @Volatile private var isRecoveryDispatched = false     // sync entry-lock (distinct from isRecovering)

    fun scheduleAutoRecovery() {
        if (autoRecoverySuspended) return
        if (isRecoveryDispatched) return
        isRecoveryDispatched = true
        scope.launch { runRecovery(userInitiated = false) }
    }

    fun triggerUserRecovery() {
        autoRecoverySuspended = false
        consecutiveAutoFailures = 0
        if (isRecoveryDispatched) return
        isRecoveryDispatched = true
        scope.launch { runRecovery(userInitiated = true) }
    }

    /** Test/instrumentation seam to launch and join a single recovery. */
    fun launchRecovery(userInitiated: Boolean = true): Job {
        isRecoveryDispatched = true
        return scope.launch { runRecovery(userInitiated) }
    }

    private suspend fun runRecovery(userInitiated: Boolean) {
        val myGen = ++recoveryGeneration
        _isRecovering.value = true
        try {
            // isAlive short-circuit: skip the whole backoff if the socket is live.
            if (isAlive()) { if (myGen == recoveryGeneration) fetchSessions(); return }

            for (delayMs in backoffMs) {
                if (myGen != recoveryGeneration) return            // newer recovery superseded us
                if (delayMs > 0) sleepMs(delayMs)
                if (myGen != recoveryGeneration) return
                _phase.value = RecoveryPhase.RECONNECTING
                val ok = runCatching { reconnect() }.isSuccess
                if (!ok) continue
                if (myGen != recoveryGeneration) return
                _phase.value = RecoveryPhase.AUTHENTICATING
                if (runCatching { reauth() }.isFailure) continue
                if (myGen != recoveryGeneration) return
                _phase.value = RecoveryPhase.RESUMING
                if (runCatching { resumeActive() }.isFailure) continue
                fetchSessions()
                consecutiveAutoFailures = 0
                return                                              // success
            }
            // exhausted backoff -> failure
            if (!userInitiated && ++consecutiveAutoFailures >= 3) autoRecoverySuspended = true
            _connectionTimedOut.value = true
        } finally {
            // defer-idempotency: always clear, even on cancellation mid-await.
            _isRecovering.value = false
            _phase.value = null
            isRecoveryDispatched = false
            lastRecoveryEndedAt = 0L   // replace with injected monotonic clock if cooldown needed
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew :core-session:test --tests "relay.session.RecoveryControllerTest"`
Expected: PASS.

- [ ] **Step 5: Commit** `feat(session): RecoveryController circuit breaker + generation guards`

---

## Task 4: `AuthCoordinator` (single-flight + withAuth retry-once)

**Files:**
- Create: `core-session/src/main/kotlin/relay/session/AuthCoordinator.kt`
- Test: `core-session/src/test/kotlin/relay/session/AuthCoordinatorTest.kt`

> Port of `AuthCoordinator.swift`: concurrent `ensureAuthenticated()` share one job; `withAuth { }` retries once when the body throws `isNotAuthenticated`.

- [ ] **Step 1: Write the failing test**

```kotlin
package relay.session

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import java.util.concurrent.atomic.AtomicInteger

class AuthCoordinatorTest {
    @Test fun `concurrent ensureAuthenticated dedupes to one auth call`() = runTest {
        val authCalls = AtomicInteger(0)
        val ac = AuthCoordinator(authenticate = { authCalls.incrementAndGet(); }, isAuthValid = { false })
        (1..5).map { async { ac.ensureAuthenticated() } }.awaitAll()
        assertEquals(1, authCalls.get())
    }
    @Test fun `withAuth retries once on not-authenticated`() = runTest {
        var attempts = 0
        val ac = AuthCoordinator(authenticate = {}, isAuthValid = { false })
        val result = ac.withAuth {
            attempts++
            if (attempts == 1) throw NotAuthenticatedException()
            "ok"
        }
        assertEquals("ok", result); assertEquals(2, attempts)
    }
}
```

- [ ] **Step 2–4: implement + pass**

```kotlin
package relay.session

import kotlinx.coroutines.CompletableDeferred

class NotAuthenticatedException : Exception("not authenticated")

class AuthCoordinator(
    private val authenticate: suspend () -> Unit,
    private val isAuthValid: () -> Boolean,
) {
    private var inFlight: CompletableDeferred<Unit>? = null

    suspend fun ensureAuthenticated() {
        if (isAuthValid()) return
        inFlight?.let { return it.await() }
        val d = CompletableDeferred<Unit>(); inFlight = d
        try { authenticate(); d.complete(Unit) }
        catch (t: Throwable) { d.completeExceptionally(t); throw t }
        finally { inFlight = null }
    }

    suspend fun <T> withAuth(body: suspend () -> T): T {
        ensureAuthenticated()
        return try { body() }
        catch (e: NotAuthenticatedException) {
            // server may have invalidated auth post-reconnect: reset + retry once
            authenticate(); body()
        }
    }
}
```

- [ ] **Step 5: Commit** `feat(session): AuthCoordinator single-flight + retry-once`

---

## Task 5: `ActivityCoordinator` + `NetworkObserver` + `ServerStatusChecker`

**Files:**
- Create: `core-session/src/main/kotlin/relay/session/ActivityCoordinator.kt`
- Create: `core-session/src/main/kotlin/relay/session/NetworkObserver.kt`
- Create: `core-session/src/main/kotlin/relay/session/ServerStatusChecker.kt`
- Test: `core-session/src/test/kotlin/relay/session/ActivityCoordinatorTest.kt`

> `ActivityCoordinator` (port of `ActivityCoordinator.swift`): `StateFlow<Map<UUID, String>>` agent map (persisted to ownership store for instant sidebar render), awaiting-input set, stolen flags. `NetworkObserver` wraps `ConnectivityManager.NetworkCallback` → emits "connectivity restored". `ServerStatusChecker` (port of `ServerStatusChecker.swift`): 15s poll, per-bookmark short-lived connect+auth, 5s timeout, `supervisorScope` + `finally` disconnect.

- [ ] **Step 1: Test `ActivityCoordinator` agent-map + stolen flag transitions** (JVM, pure logic):

```kotlin
@Test fun `applyActivity updates agent map and clears on null`() { /* set agentActive+agent -> map has id; set active+null -> map removed */ }
@Test fun `sessionStolen sets flag and unclaims`() { /* assert showStolen true + unclaim called */ }
```

- [ ] **Step 2–4:** implement `ActivityCoordinator` with injected `ownershipStore`; persist agent on every change. `NetworkObserver` and `ServerStatusChecker` are Android/coroutine glue — specify behavior; verify `NetworkObserver` manually (toggle airplane mode) and `ServerStatusChecker` via an instrumented test against the dev server (assert a reachable bookmark → live, an unreachable host:port → offline within ~5s).

- [ ] **Step 5: Commit** `feat(session): activity coordinator, network observer, status checker`

---

## Task 6: `SessionCoordinator` — wire it all together

**Files:**
- Create: `core-session/src/main/kotlin/relay/session/SessionCoordinator.kt`
- Test: `core-session/src/test/kotlin/relay/session/SessionCoordinatorTest.kt`

> Port of `SharedSessionCoordinator.swift`. Owns `StateFlow`s for `sessions`, `activeSessionId`, recovery state (delegated to `RecoveryController`), the `TerminalCache`, and the coordinators. Each session-op RPC is wrapped in `authCoordinator.withAuth { }` and guarded by `!isRecovering`.
>
> **⚠️ The four ops are DISTINCT sequences — do NOT collapse into one shared flow** (corrections §A5, verified against `SharedSessionCoordinator.swift`):
> - **CREATE** (`:392-412`): `withAuth { detach?; createSession }` → `claimSession` → `wireTerminalOutput` (**after** the RPC) → set active → `touch` → `enforceLimit` → `fetchSessions`.
> - **SWITCH** (`:433-458`): `prepareForSwitch(prev)` → `beginReplay(incoming)` → **`wireTerminalOutput` BEFORE** `withAuth { detach; resume }` → set active → `touch` → `enforceLimit` → `fetchSessions`. **No `claim`.** (Comment `:433-434`: wire before resume so binary replay frames route to the correct VM.)
> - **ATTACH** (`:477-522`): `withAuth { detach?; attachSession }` → `claimSession` → `vm.beginReplay()` → `wireTerminalOutput` (after) → set active → `touch` → `enforceLimit` → names → `fetchSessions`, **with previous-session rollback on failure** (`:510-514`: on catch, `resumeSession(previousId)` + re-wire).
> - **TERMINATE** (`:568-578`): `connection.send(.sessionTerminate)` → clear active → `evictTerminal` → `forgetSession` (activity) → `unclaimSession` → remove name+title → `fetchSessions`.
>
> **Eager output wiring (the "before resume" rule) applies to the SWITCH path only** — for create/attach the wiring is *after* the RPC.

- [ ] **Step 1: Write failing tests for the op sequences (fake controller/connection)**

```kotlin
@Test fun `createSession does withAuth then claim, wire(after), active, touch, enforceLimit, fetch`() { /* CREATE order */ }
@Test fun `switchSession wires BEFORE resume and does NOT claim`() { /* assert wire precedes resume; no claim call */ }
@Test fun `switchSession endReplay fires on replayComplete`() { /* onReplayComplete -> activeVm.endReplay() */ }
@Test fun `attachRemote rolls back to previous session on attach failure`() { /* catch -> resume(previousId) + re-wire */ }
@Test fun `terminate sends terminate, clears active, evicts, forgets activity, unclaims, fetches`() { /* forget BEFORE unclaim */ }
@Test fun `ops are no-ops while isRecovering`() { /* assert guarded */ }
```

- [ ] **Step 2–4:** implement the coordinator. Key methods mirror Swift: `createSession`, `switchTo(id)`, `attachRemote(id)`, `terminate(id)`, `fetchSessions`, `handleForegroundTransition`, plus output-routing wiring and `onSessionActivity`/`onSessionStolen`/`onReplayComplete` handlers (the latter calls the active VM's `endReplay()`). Connect `RecoveryController` collaborators to real `connection`/`auth`/`resume`/`fetch` lambdas.

> Reproduce the iOS create/switch/terminate sequences exactly (they fixed real race bugs). Use the M1 `RelayConnection`/`SessionController` and M2 `TerminalCache`/coordinators.

- [ ] **Step 5: Commit** `feat(session): SessionCoordinator orchestrator`

---

## Task 7: `:feature-servers` — server list + add/edit (Compose)

**Files:** `feature-servers/.../ServersScreen.kt`, `AddEditServerSheet.kt`, `ServersViewModel.kt`

> UI — manual verification. Port of `ServerListView.swift`/`AddEditServerView.swift`. `LazyColumn` of bookmarks with live/offline dot (from `ServerStatusChecker`), **pull-to-refresh** (`PullRefreshIndicator`), **swipe edit(blue)/delete(red)** (`SwipeToDismissBox`), empty-state Composable. Add/edit `ModalBottomSheet`: name/host/port/TLS toggle/token (`PasswordVisualTransformation`), host-non-empty validation, delete-confirm `AlertDialog`. On connect: validate via `CleartextPolicy` (reject ws:// to non-private with a "TLS required" message), then navigate to workspace.

- [ ] **Step 1:** Build the screens + VM (VM holds `StateFlow<List<ConnectionConfig>>` from `SavedConnectionStore`, status map from `ServerStatusChecker`).
- [ ] **Step 2:** Manual verify: add a server, see live dot, edit via swipe, delete with confirm, connect → workspace, ws:// to a public host shows TLS-required error.
- [ ] **Step 3: Commit** `feat(servers): server list + add/edit screens`

---

## Task 8: `:feature-workspace` — adaptive split, sidebar, tabs, terminal host

**Files:** `feature-workspace/.../WorkspaceScreen.kt`, `SessionSidebar.kt`, `SessionTabs.kt`, `TerminalHost.kt`, `ConnectionQualityDot.kt`, `ActivityDot.kt`, `AgentColorPalette.kt`, `TerminalPalette.kt`

> UI — manual verification. Port of `WorkspaceView`/`SessionSidebarView`/`ActiveTerminalView` and the shared `Views/` atoms.

- [ ] **Step 1: Adaptive layout** via `currentWindowAdaptiveInfo()`: Expanded → two-pane (sidebar | terminal); Compact → terminal full-screen + sidebar as `ModalBottomSheet`/drawer.
- [ ] **Step 2: Sidebar** — New/Attach buttons, session list with state badges + `ActivityDot`, rename `AlertDialog`, swipe-delete, **long-press context menu** (rename / share QR), pull-to-refresh.
- [ ] **Step 3: Tabs** — `LazyRow`, numbered, agent-colored, flash when `awaitingInput`. Port `AgentColorPalette` keyed on the `agentId` **String** (corrections §B1; do NOT port the server-only `CodingAgent` registry): `"claude" → orange`, `"codex" → Color(red=84/255, green=132/255, blue=137/255)` (teal), and **default → the same teal** as codex (`AgentColorPalette.swift:12-14`). Also port `TerminalPalette` (`TerminalPalette.swift:8-25`) — the 16-color ANSI palette — and install it into the Termux engine (the iOS `RelayTerminalView.swift:266` analog).
- [ ] **Step 4: Status bar** — sidebar toggle, disconnect, key-bar toggle, `ConnectionQualityDot` (excellent/good=green, poor/veryPoor=yellow blinking via `rememberInfiniteTransition`, disconnected=red), uptime timer (days + HH:MM:SS), QR share, name badge (long-press → rename).
- [ ] **Step 5: Terminal host** — `AndroidView { RelayTerminalView }` bound to the active VM; wires `onInput`/`onResize`; hosts `KeyboardAccessory`.
- [ ] **Step 6: Recovery overlay** — observes `coordinator.isRecovering`/`phase`; modal with progress + phase label + cancel; `BackHandler` suppresses dismiss during recovery (the `interactiveDismissDisabled` analog).
- [ ] **Step 7: Manual verify** — create 3 sessions, switch via tabs (scrollback restored in one paint), rename, kill, attention-flash on idle agent, kill Wi-Fi → recovery overlay → restore. Foldable: fold/unfold reflows. **This is the M2 acceptance test.**
- [ ] **Step 8: Commit** `feat(workspace): adaptive split, sidebar, tabs, terminal host, recovery overlay`

---

## Task 9: QR share + scan, deep links

**Files:** `feature-workspace/.../QrShareSheet.kt`, `QrScannerScreen.kt`; `app/.../DeepLinks.kt` + manifest intent-filter

> Port of `QRCodeSheet`/`QRScannerView`. **ZXing** generates the QR of `coderelay://session/{UUID}`; **CameraX + ML Kit barcode** scans. Deep link via `intent-filter` (`VIEW`/`BROWSABLE`, scheme `clauderelay`); handle cold-start (`onCreate`) + warm (`onNewIntent`) → `pendingSessionId`, consumed on workspace entry → `attachRemote(id)`.

- [ ] **Step 1: Test the deep-link parser (pure JVM):**

```kotlin
@Test fun `parses session deep link`() {
    assertEquals(UUID.fromString("550e8400-e29b-41d4-a716-446655440000"),
        DeepLinks.parseSessionId("coderelay://session/550e8400-e29b-41d4-a716-446655440000"))
    assertNull(DeepLinks.parseSessionId("coderelay://nonsense"))
}
```

- [ ] **Step 2–4:** implement `DeepLinks.parseSessionId`, the QR sheet (ZXing `Bitmap`), the scanner (CameraX preview + ML Kit analyzer → parse → attach), haptic on detect.
- [ ] **Step 5: Manual verify** — share a session QR from one device, scan from another → attach succeeds; tap a `coderelay://session/<uuid>` link cold + warm → attaches.
- [ ] **Step 6: Commit** `feat(workspace): QR share/scan + deep links`

---

## Task 10: `:feature-settings` — AppSettings (DataStore: 14 keys) + Bedrock token (Keychain)

**Files:** `feature-settings/.../SettingsScreen.kt`, `AppSettings.kt`, `KeyCapture.kt`

> Port of `SettingsView.swift`/`AppSettings.swift`. `AppSettings` backed by DataStore (Bedrock token via `TokenStore`, 500ms debounced write through `Flow.debounce(500)`).
>
> **The exact 14 `@AppStorage` keys + defaults (`AppSettings.swift:112-145`):**
> `smartCleanupEnabled=true`, `promptEnhancementEnabled=false`, `bedrockRegion="us-east-1"`,
> `hapticFeedbackEnabled=true`, `autoConnectEnabled=false`, `lastConnectedServerId=""`,
> `sessionNamingTheme=gameOfThrones`, `terminalFontSize=12.0`, `terminalScrollbackLines=5000`,
> `recordingShortcutEnabled=true`, `recordingShortcutFlags=[command,option]`,
> `recordingShortcutKey=""`, `continuousListeningEnabled=false`, `wakeWord="claude"`.
> Plus `bedrockBearerToken` in the Keychain/EncryptedSharedPreferences (`@Published`, **not**
> `@AppStorage`) = 15 persisted prefs. `turnEndSilenceTimeout` is **not** a setting.
>
> **Two migrations to port** (`AppSettings.swift:31-98`): (a) `recordingShortcutModifier`
> string → `recordingShortcutFlags` Int; (b) legacy UserDefaults `bedrockBearerToken` →
> Keychain with read-back-confirm-before-delete + plaintext fallback. The Bedrock debounce
> uses **`.dropFirst()`** — the initial seed must NOT trigger a write.

- [ ] **Step 1: Test AppSettings persistence (instrumented)** — set/read each of the 14 keys (default + override); assert the Bedrock token round-trips through the Keychain store and that the seed write is suppressed (`.dropFirst()` analog).
- [ ] **Step 2–4: implement** the settings sections exactly: **Speech** (Smart Cleanup, Prompt Enhancement, Continuous Listening + wake-word display — wake-word editing UI present but engine lands in M3), **Bedrock** (token masked + region; validation alert if enhancement on + token empty), **Connection** (Auto-Connect), **General** (Haptic Feedback, Naming theme picker, Font Size stepper 8–16, Scrollback picker 1k/5k/10k/25k), **Keyboard Shortcuts** (recording-shortcut toggle + `KeyEvent.META_*`+keycode capture), **About** (version/build from `BuildConfig`).
- [ ] **Step 5: Manual verify** — toggle each setting, relaunch, values persist; font-size/scrollback affect the terminal; auto-connect reconnects on launch.
- [ ] **Step 6: Commit** `feat(settings): full settings screen + AppSettings store`

---

## Task 11: `:app` navigation graph + foreground-recovery wiring

**Files:** `app/.../RelayNavGraph.kt`, `MainActivity.kt` (replaces M1 demo)

> Replace the M1 demo with the real nav graph: Splash → Servers → Workspace (+ Settings, sheets). Wire `Lifecycle.Event.ON_RESUME` → `coordinator.handleForegroundTransition()` (the `scenePhase==.active` analog) via `repeatOnLifecycle`. Wire `NetworkObserver` "restored" → `triggerUserRecovery()`. Splash animates (port `SplashScreenView`) and triggers model-preload hook (no-op until M3).

- [ ] **Step 1–2:** implement nav graph + lifecycle wiring.
- [ ] **Step 3: Manual verify (M2 acceptance):** cold launch → splash → servers → connect → workspace; background 30s → foreground → `isAlive` short-circuit refreshes without a full reconnect; kill Wi-Fi mid-session → 3 failures → recovery overlay → restore on reconnect; rotate/fold → layout reflows, session preserved.
- [ ] **Step 4: Commit** `feat(app): real navigation graph + foreground/network recovery wiring`

---

## M2 Self-Review Checklist

- [ ] Recovery: alive short-circuit, 3-auto-failure breaker, user-reset, generation bail, cancel-clears-flag (Task 3 tests).
- [ ] Auth: single-flight dedup + retry-once (Task 4 tests).
- [ ] LRU-8 never evicts active (Task 2 test).
- [ ] Ownership: device-scoped key + diff-checked writes (Task 1 instrumented test).
- [ ] Adaptive layout reflows phone↔tablet/foldable (Task 8 manual).
- [ ] Tabs/sidebar/activity dots/quality dot parity (Task 8 manual).
- [ ] QR share/scan + deep links cold+warm (Task 9 manual).
- [ ] All settings persist + take effect: 14 `@AppStorage` keys + 1 Keychain Bedrock token (Task 10).
- [ ] Foreground + network recovery end-to-end (Task 11 manual).
- [ ] Every iOS screen has an Android counterpart (cross-check the spec's screen parity map).
