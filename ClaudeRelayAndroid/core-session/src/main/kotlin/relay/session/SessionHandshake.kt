package relay.session

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import relay.net.SessionException
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

/**
 * The one and only way the session pane gets populated:
 *
 *     open the socket → authenticate → ask the server which sessions this
 *     client owns → render them
 *
 * ALWAYS, on every entry into a live workspace: cold launch, foreground,
 * wake-from-sleep, network restored. No conditionals, no "only if the pane is
 * empty", no path that skips a step.
 *
 * Port of Sources/ClaudeRelayClient/ViewModels/SessionHandshake.swift, kept
 * behaviorally identical so a fix on one client is a fix on all of them.
 *
 * **Why this type exists.** That flow used to be spread across
 * [SessionCoordinator.connect], [SessionCoordinator.fetchSessions] and the two
 * short-circuits inside [RecoveryController.handleForegroundTransition] — call
 * sites racing each other over one socket, each with its own idea of whether
 * auth had happened. Five shipped fixes each closed one race and the pane still
 * came up empty. The fix is not another guard: it's making the sequence a
 * single, single-flight, retrying unit that nothing else can interleave with.
 *
 * **Invariants this type enforces:**
 *  1. *Single-flight.* Concurrent callers (launch `connect()` + `ON_RESUME` +
 *     network-restored all fire within ~100 ms of each other on a cold launch)
 *     share ONE in-flight handshake. Nobody issues a second `auth_request` or a
 *     parallel `session_list`.
 *  2. *No silent failure.* Every attempt either renders the server's list or
 *     retries; total failure surfaces a real error. The old launch path let
 *     [SessionCoordinator.fetchSessions] swallow the RPC failure, so one
 *     transient error meant a permanently blank pane.
 *  3. *Ordered.* Auth completes before `session_list` is sent. The auth
 *     round-trip doubles as the liveness proof for the socket, so no separate
 *     ping is needed (and a fresh socket can't be mistaken for a dead one).
 *  4. *Uninterruptible.* While a handshake runs, [RecoveryController] refuses
 *     to reconnect — recovery tearing the socket out from under the launch
 *     fetch was the last root cause.
 *
 * Confinement: like everything else in this layer, not thread-safe. Every entry
 * point must run on the coordinator's single (main) dispatcher — the
 * single-flight slot relies on that confinement, exactly as [AuthCoordinator]
 * does.
 */
class SessionHandshake internal constructor(
    private val coordinator: SessionCoordinator,
    private val scope: CoroutineScope,
) {

    /**
     * Why the handshake is running. Controls exactly one thing: whether sessions
     * that vanished from the server's list are announced to the user.
     */
    enum class Reason {
        /**
         * Cold app launch. Sessions another client took while this app was
         * closed are simply absent from the list — the user is NOT told, per
         * product spec: there is no "before" to compare against, and reporting
         * it on every launch is noise.
         */
        LAUNCH,

        /**
         * The app was already open and is coming back: foreground, wake from
         * sleep, network restored, post-reconnect. Here there IS a "before", so
         * a session that dropped out of the list while we were away is
         * announced as "attached by another client" — the live `session_stolen`
         * push that would normally do it was missed because our socket was down.
         */
        WAKE,
        ;

        val label: String get() = if (this == LAUNCH) "launch" else "wake"
    }

    /**
     * The single in-flight handshake, if any. Concurrent callers await it rather
     * than starting their own pass (see invariant 1).
     */
    private var inFlight: CompletableDeferred<Boolean>? = null
    private var job: Job? = null

    // MARK: - Entry point

    /**
     * Runs (or joins) the handshake. Returns true once the pane reflects the
     * server's authoritative list for this token — including the legitimate
     * "you own zero sessions" answer, which is a SUCCESS, not a retry case.
     */
    suspend fun perform(reason: Reason): Boolean {
        // Single-flight. A second caller does not get its own pass: the
        // in-flight one is already doing precisely what it wants, and a parallel
        // `session_list` is a needless round-trip against a socket the other
        // pass may be replacing.
        inFlight?.let { return it.await() }

        val deferred = CompletableDeferred<Boolean>()
        // Slot + gate are armed BEFORE the coroutine is launched, so a recovery
        // trigger that lands in between is still gated out (the launch race).
        inFlight = deferred
        coordinator.setHandshakeInFlight(true)
        job = scope.launch {
            var ok = false
            try {
                ok = run(reason)
            } finally {
                // Runs on success, failure AND cancellation, so the gate can
                // never strand — a stuck gate would block recovery forever —
                // and a joiner can never hang on an abandoned pass.
                if (inFlight === deferred) {
                    inFlight = null
                    coordinator.setHandshakeInFlight(false)
                }
                deferred.complete(ok)
            }
        }
        return deferred.await()
    }

    /**
     * Cancels the in-flight pass and clears the gate. Called from
     * [SessionCoordinator.tearDown] so a coordinator that goes away mid-handshake
     * doesn't leave the recovery gate armed.
     */
    fun invalidate() {
        job?.cancel()
        job = null
        inFlight?.complete(false)
        inFlight = null
        coordinator.setHandshakeInFlight(false)
    }

    // MARK: - The flow

    private suspend fun run(reason: Reason): Boolean {
        if (coordinator.isTornDown) return false

        // Snapshot the pane BEFORE the fetch so a WAKE pass can tell the user
        // which sessions another device took while we were away. Captured with
        // names, because applying the server list prunes the name map — after
        // that runs, the lost session's name is gone.
        val before = coordinator.activeSessions.value.map { LostSession(it.id, coordinator.name(it.id)) }

        RETRY_DELAYS_MS.forEachIndexed { attempt, delayMs ->
            // delay() throws CancellationException on teardown, which propagates
            // out of run() into perform()'s finally — gate cleared, joiners
            // completed false.
            if (delayMs > 0L) delay(delayMs)
            if (coordinator.isTornDown) return false

            try {
                // 1. A socket. `!isConnected` covers both "never connected" and
                //    "the socket died since" — including a receive-loop failure,
                //    which does NOT bump the connection generation.
                if (!coordinator.connection.isConnected) {
                    coordinator.connection.forceReconnect()
                }

                // 2. Authenticate. This is also the liveness proof: the
                //    auth_request → auth_success round-trip exercises the full
                //    socket end to end. A separate ping would tell us less (the
                //    server answers pings pre-auth) and later.
                coordinator.authCoordinator.ensureAuthenticated()
                if (coordinator.isTornDown) return false

                // 3. Ask the server which sessions this client owns.
                //    `listSessions()` is TOKEN-scoped server-side — that IS the
                //    answer to "what do I own", and the server is authoritative.
                val owned = coordinator.sessionController.listSessions()
                if (coordinator.isTornDown) return false

                // 4. Render.
                coordinator.applyServerSessions(owned)
                if (reason == Reason.WAKE) announceSessionsTakenElsewhere(before)

                // A completed handshake means the connection is demonstrably
                // healthy: clear any stale failure banners from an earlier pass.
                coordinator.recoveryController.clearTerminalFlags()
                return true
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: Throwable) {
                if (isTokenRejection(error)) {
                    // Retrying a rejected token cannot succeed, and hammering
                    // the server trips its rate limiter. Stop and let the user
                    // re-pair.
                    fail(error)
                    return false
                }
                // Assume the socket is the problem, because it usually is: a
                // launch/reconnect race replaced it, or it died silently. Drop
                // both it and the auth bound to it so the next attempt starts
                // from a clean, freshly-authenticated socket rather than
                // retrying over the same broken transport.
                coordinator.sessionController.resetAuth()
                runCatching { coordinator.connection.disconnect() }

                if (attempt == RETRY_DELAYS_MS.lastIndex) {
                    fail(error)
                    return false
                }
            }
        }
        return false
    }

    // MARK: - Outcomes

    /**
     * Report a session that dropped out of the server's list while we were away.
     * One notice is enough — this is a notification, not a queue.
     */
    private fun announceSessionsTakenElsewhere(before: List<LostSession>) {
        val stillOwned = coordinator.sessions.value.map { it.id }.toSet()
        val lost = firstLostSession(before, stillOwned) ?: return
        coordinator.activityCoordinator.sessionStolen(lost.id) { lost.name }
    }

    /**
     * Surface a handshake that could not complete. Deliberately does NOT set the
     * terminal `connectionTimedOut` flag — that tears the workspace down, and the
     * right response to "couldn't load the list" is to let the user retry
     * (pull-to-refresh, or the next foreground) against a workspace that is still
     * on screen.
     */
    private fun fail(error: Throwable) {
        coordinator.presentHandshakeFailure(error)
    }

    /** A pane row captured before the fetch, so its name survives the prune. */
    internal data class LostSession(val id: UUID, val name: String)

    companion object {
        /**
         * Retry schedule. Five attempts over ~3.75 s of delay. Front-loaded
         * because the overwhelmingly common failure is a socket that was
         * replaced milliseconds ago (launch race, reconnect) and succeeds on the
         * next try — while the tail accommodates a server still coming up.
         */
        val RETRY_DELAYS_MS = longArrayOf(0, 250, 500, 1_000, 2_000)

        /**
         * The first session that was in the pane before the handshake and is not
         * in the server's fresh token-scoped list — i.e. another device attached
         * it while we were away. Pure, so the rule is testable without a server.
         *
         * `before` arrives ordered by `createdAt` (it comes from
         * `activeSessions`), so the session reported is deterministic rather than
         * set-iteration luck.
         */
        internal fun firstLostSession(
            before: List<LostSession>,
            stillOwned: Set<UUID>,
        ): LostSession? = before.firstOrNull { it.id !in stillOwned }

        /**
         * True for errors that mean "this token will never be accepted", as
         * opposed to a transport hiccup worth retrying. Matched on the two
         * messages [relay.net.SessionController.authenticate] throws for a
         * rejected token / incompatible protocol; everything else (timeouts,
         * unexpected responses) is retriable.
         */
        internal fun isTokenRejection(error: Throwable): Boolean {
            if (error !is SessionException) return false
            val message = error.message ?: return false
            return message.contains("Authentication failed", ignoreCase = true) ||
                message.contains("not compatible", ignoreCase = true)
        }
    }
}
