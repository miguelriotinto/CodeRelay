package relay.session

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withTimeoutOrNull
import relay.protocol.ConnectionConfig
import java.util.UUID

/**
 * Liveness of a saved server, ported from
 * Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift.
 *
 * [CHECKING] is the transient state while a probe is in flight; [LIVE] /
 * [OFFLINE] are the terminal results of a probe. The Swift `ServerStatus` only
 * carries `isLive`; the Android server-list UI distinguishes "never checked /
 * in flight" from "checked, offline", so we model the third state explicitly.
 */
enum class ServerStatus { CHECKING, LIVE, OFFLINE }

/**
 * Polls every saved server's liveness on a fixed interval, ported from
 * `ServerStatusChecker.swift`.
 *
 * Behavior verified against the Swift source:
 *  - **15 s poll interval** (ServerStatusChecker.swift:18, default
 *    `interval = 15`): [startPolling] runs `checkAll` then sleeps [intervalMs]
 *    in a cancellation-checked loop (ServerStatusChecker.swift:26-32).
 *  - **5 s per-probe timeout** (ServerStatusChecker.swift:94, `Task.sleep(5)`
 *    racer): each probe is wrapped in [withTimeoutOrNull] of [PROBE_TIMEOUT_MS];
 *    a probe that doesn't resolve in 5 s is recorded [OFFLINE], exactly like the
 *    Swift timeout racer winning the `withTaskGroup` race.
 *  - **supervisorScope + per-probe isolation** (ServerStatusChecker.swift:45-56,
 *    `withTaskGroup`): [checkAll] launches all probes inside a [supervisorScope]
 *    so one server's failure can't cancel the others. A probe's exception is
 *    swallowed → [OFFLINE].
 *  - **finally-disconnect** (ServerStatusChecker.swift:74-90, the
 *    `withTaskCancellationHandler { ... } onCancel: { disconnect() }` + the
 *    trailing idempotent `connection.disconnect()` at :106): the injected
 *    [probe] is responsible for the connect→auth→**disconnect** lifecycle in its
 *    own `try/finally`. This checker guarantees the probe coroutine is cancelled
 *    when the 5 s timeout wins, so the probe's `finally` fires and the socket is
 *    torn down — no FD/URLSession leak.
 *
 * Pure-JVM: the connect+auth+disconnect lifecycle is injected as [probe] (the
 * `:app` layer builds it from `RelayConnection` + `SessionController` +
 * `TokenStore`), so the poll loop and timeout/supervisor wiring stay
 * headless-testable with a fake probe + virtual time — the same injection
 * pattern as [RecoveryController]. A `null` token (no saved auth) must make the
 * probe return [OFFLINE]/false, mirroring the Swift early `return ServerStatus()`
 * at ServerStatusChecker.swift:60-62.
 *
 * Not thread-safe across dispatchers (Swift original is `@MainActor`): confine
 * [startPolling] / [stopPolling] / [refresh] to a single dispatcher via [scope].
 *
 * @param scope the loop runs on. The `:app` wiring should confine it to the main
 *   dispatcher to match the Swift `@MainActor` model.
 * @param probe performs one connect→auth→disconnect for a config and returns
 *   `true` iff the server is live (auth succeeded). Must do its own `try/finally`
 *   disconnect; this checker enforces the 5 s timeout and cancels on timeout.
 * @param intervalMs poll interval; defaults to 15 s (Swift default). Injectable
 *   for virtual-time tests.
 * @param sleepMs inter-poll sleep; injectable so tests drive virtual time.
 */
class ServerStatusChecker(
    private val scope: CoroutineScope,
    private val probe: suspend (ConnectionConfig) -> Boolean,
    private val intervalMs: Long = DEFAULT_INTERVAL_MS,
    private val sleepMs: suspend (Long) -> Unit = { delay(it) },
) {
    private val _statuses = MutableStateFlow<Map<UUID, ServerStatus>>(emptyMap())

    /** Liveness keyed by [ConnectionConfig.id] (Swift `statuses`). */
    val statuses: StateFlow<Map<UUID, ServerStatus>> = _statuses.asStateFlow()

    private var pollJob: Job? = null

    /**
     * Starts (or restarts) polling [connections]. Cancels any prior loop first,
     * runs an immediate `checkAll`, then loops `checkAll`→sleep until cancelled
     * (ServerStatusChecker.swift:22-33). No-op for an empty list.
     */
    fun startPolling(connections: List<ConnectionConfig>) {
        pollJob?.cancel()
        if (connections.isEmpty()) {
            pollJob = null
            return
        }
        pollJob = scope.launch {
            while (isActive) {
                checkAll(connections)
                sleepMs(intervalMs)
            }
        }
    }

    /** Stops polling and cancels any in-flight probes (Swift `stopPolling`). */
    fun stopPolling() {
        pollJob?.cancel()
        pollJob = null
    }

    /** Restarts polling with a fresh connection list (Swift `refresh`). */
    fun refresh(connections: List<ConnectionConfig>) = startPolling(connections)

    /**
     * Probes every connection concurrently under a [supervisorScope] so a single
     * server's failure or timeout can't cancel the others
     * (ServerStatusChecker.swift:44-56). Each config is flipped to [CHECKING]
     * while in flight, then to [LIVE]/[OFFLINE] on result.
     */
    suspend fun checkAll(connections: List<ConnectionConfig>) {
        // Mark all in-flight (transient CHECKING) before probing.
        _statuses.value = _statuses.value.toMutableMap().apply {
            for (config in connections) put(config.id, ServerStatus.CHECKING)
        }

        supervisorScope {
            connections.map { config ->
                async {
                    val live = checkOne(config)
                    config.id to if (live) ServerStatus.LIVE else ServerStatus.OFFLINE
                }
            }.awaitAll().forEach { (id, status) ->
                _statuses.value = _statuses.value + (id to status)
            }
        }
    }

    /**
     * One liveness probe with the 5 s timeout racer (ServerStatusChecker.swift:
     * 68-101). On timeout [withTimeoutOrNull] cancels the [probe] coroutine,
     * firing its `finally` disconnect, and returns `false` → [OFFLINE]. Any probe
     * exception is swallowed to `false` so it can't escape the supervisor scope.
     */
    private suspend fun checkOne(config: ConnectionConfig): Boolean =
        try {
            withTimeoutOrNull(PROBE_TIMEOUT_MS) { probe(config) } ?: false
        } catch (_: Throwable) {
            false
        }

    companion object {
        /** Poll interval, ms — Swift default `interval = 15` (ServerStatusChecker.swift:18). */
        const val DEFAULT_INTERVAL_MS = 15_000L

        /** Per-probe timeout, ms — Swift `Task.sleep(.seconds(5))` racer (ServerStatusChecker.swift:94). */
        const val PROBE_TIMEOUT_MS = 5_000L
    }
}
