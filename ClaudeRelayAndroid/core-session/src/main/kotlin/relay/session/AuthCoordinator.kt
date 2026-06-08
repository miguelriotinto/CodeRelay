package relay.session

import kotlinx.coroutines.CompletableDeferred

/**
 * Thrown by a `withAuth` body when the server reports the handler is not
 * authenticated (typically after a transport reconnect leaves the server with
 * a fresh, unauthenticated handler). Maps to Swift's
 * `SessionController.SessionError.isNotAuthenticated` branch
 * (AuthCoordinator.swift:96).
 */
class NotAuthenticatedException : Exception("not authenticated")

/**
 * Owns the authentication surface ported from
 * Sources/ClaudeRelayClient/AuthCoordinator.swift:
 *
 *  - Single-flight: concurrent [ensureAuthenticated] callers share one
 *    in-flight authentication instead of each firing its own `auth_request`
 *    and racing into the server's "Already authenticated" reject path
 *    (AuthCoordinator.swift:36-40, 73-87).
 *  - [withAuth] runs a body with auth ensured and auto-retries the body
 *    exactly once on a [NotAuthenticatedException], re-authenticating first
 *    (AuthCoordinator.swift:92-101).
 *
 * The Swift original threads a `SessionController` through; on Android that
 * coupling lives in the coordinator, so this port is parameterised by injected
 * lambdas — [authenticate] (performs the auth round-trip and updates whatever
 * state [isAuthValid] reads), [isAuthValid] (the local "is the cached auth
 * still valid for the current connection generation" bit), and [resetAuth]
 * (clears the local auth bit so the next [ensureAuthenticated] re-authenticates;
 * parity with Swift's `sessionController?.resetAuth()` at
 * AuthCoordinator.swift:97).
 *
 * Not thread-safe across dispatchers — the Swift original is `@MainActor`
 * isolated. Callers must confine access to a single (main) dispatcher; the
 * single-flight deduplication relies on that confinement.
 */
class AuthCoordinator(
    private val authenticate: suspend () -> Unit,
    private val isAuthValid: () -> Boolean,
    private val resetAuth: () -> Unit = {},
) {
    /**
     * Single-flight handle. Concurrent callers await the same `CompletableDeferred`
     * instead of starting a second authentication (AuthCoordinator.swift:40).
     */
    private var inFlight: CompletableDeferred<Unit>? = null

    /**
     * Ensure the connection is authenticated. Returns immediately when the
     * cached auth is still valid; otherwise performs (or joins) a single
     * in-flight authentication (AuthCoordinator.swift:69-87).
     */
    suspend fun ensureAuthenticated() {
        if (isAuthValid()) return
        inFlight?.let { return it.await() }

        val deferred = CompletableDeferred<Unit>()
        inFlight = deferred
        try {
            authenticate()
            deferred.complete(Unit)
        } catch (t: Throwable) {
            deferred.completeExceptionally(t)
            throw t
        } finally {
            // Mirror Swift's `defer { if authTask == task { authTask = nil } }`:
            // only clear the slot if it still points at this attempt.
            if (inFlight === deferred) inFlight = null
        }
    }

    /**
     * Run [body] with auth ensured. If [body] throws [NotAuthenticatedException]
     * (the server saw a fresh unauthenticated handler after a reconnect),
     * re-authenticate and retry the body exactly once. A second
     * [NotAuthenticatedException] — or any non-auth error — propagates
     * (AuthCoordinator.swift:92-101).
     */
    suspend fun <T> withAuth(body: suspend () -> T): T {
        ensureAuthenticated()
        return try {
            body()
        } catch (e: NotAuthenticatedException) {
            // Swift: `sessionController?.resetAuth(); ensureAuthenticated()`
            // (AuthCoordinator.swift:97-98). resetAuth() clears the local
            // auth bit so the following ensureAuthenticated() can't short-circuit
            // on a stale-valid flag and instead routes through the single-flight
            // `inFlight` slot. Calling ensureAuthenticated() — NOT authenticate()
            // directly — is the load-bearing detail: when two concurrent withAuth
            // bodies both throw NotAuthenticated (the post-reconnect
            // mass-invalidation case), both retries dedupe through the shared
            // in-flight authentication instead of each racing its own
            // auth_request.
            resetAuth()
            ensureAuthenticated()
            body()
        }
    }
}
