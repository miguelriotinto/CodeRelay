package relay.net

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ClientMessage
import relay.protocol.ServerMessage
import relay.protocol.SessionInfo
import relay.protocol.SessionState
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * Test double for [ConnectionSurface]. [autoRespond] feeds a canned server
 * message to the installed subscriber synchronously on `send`, so the "response
 * beats the await" path (the race the real code defends against) is exercised
 * without any real socket or timer. [deliver] feeds the installed subscribers a
 * message out-of-band (after the awaiter has suspended) for the async/duplicate
 * delivery paths.
 *
 * Subscriber bookkeeping is lock-guarded and [sentMessages] is copy-on-write
 * because the real [RelayConnection] fans messages out on its own confinement
 * dispatcher while the controller installs and removes subscribers on the caller's
 * thread. Most tests here run single-threaded and don't need that, but the ones
 * that reproduce cross-dispatcher delivery do — and an unsynchronized
 * `LinkedHashMap` would fail them with a spurious `ConcurrentModificationException`
 * instead of the assertion under test. Insertion order is preserved (rather than
 * switching to a `ConcurrentHashMap`) because the fan-out-order tests depend on it.
 */
private class FakeConnection(
    var autoRespond: ((ClientMessage) -> ServerMessage?)? = null,
) : ConnectionSurface {
    @Volatile
    override var generation: Long = 7L

    /** Whether a socket is up. Mutable so a test can model the receive-loop
     *  failure that drops the socket WITHOUT bumping [generation]. */
    @Volatile
    override var isConnected: Boolean = true
    var sentMessages: MutableList<ClientMessage> = CopyOnWriteArrayList()
    private val lock = Any()
    private val subscribers = LinkedHashMap<UUID, (ServerMessage) -> Unit>()

    override fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID {
        val id = UUID.randomUUID()
        synchronized(lock) { subscribers[id] = handler }
        return id
    }

    override fun removeSubscriber(id: UUID) {
        synchronized(lock) { subscribers.remove(id) }
    }

    private fun currentSubscribers(): List<(ServerMessage) -> Unit> =
        synchronized(lock) { subscribers.values.toList() }

    override suspend fun send(message: ClientMessage) {
        sentMessages.add(message)
        autoRespond?.invoke(message)?.let { response ->
            // Deliver synchronously, mirroring a response that arrives during send.
            currentSubscribers().forEach { it(response) }
        }
    }

    /** Fans [response] out to every installed subscriber (out-of-band delivery). */
    fun deliver(response: ServerMessage) {
        currentSubscribers().forEach { it(response) }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class SessionControllerTest {

    @Test
    fun `authenticate succeeds on AuthSuccess`() = runTest {
        val conn = FakeConnection(autoRespond = { ServerMessage.AuthSuccess(protocolVersion = 1) })
        val controller = SessionController(conn)

        controller.authenticate("tok")

        assertTrue(controller.isAuthenticated)
        assertEquals(conn.generation, controller.authenticatedGeneration)
        val sent = conn.sentMessages.single() as ClientMessage.AuthRequest
        assertEquals("tok", sent.token)
        assertEquals(ProtocolVersions.CURRENT, sent.protocolVersion)
    }

    @Test
    fun `authenticate throws on AuthFailure`() = runTest {
        val conn = FakeConnection(autoRespond = { ServerMessage.AuthFailure("bad token") })
        val controller = SessionController(conn)

        val ex = assertThrows(SessionException::class.java) {
            // runTest body is a coroutine; bridge the suspend call.
            kotlinx.coroutines.runBlocking { controller.authenticate("tok") }
        }
        assertTrue(ex.message!!.contains("bad token"))
        assertFalse(controller.isAuthenticated)
    }

    @Test
    fun `authenticate treats 400 Already authenticated as success`() = runTest {
        // Regression: a redundant auth on an already-authenticated socket gets
        // `error(400, "Already authenticated")` from the server. That's a
        // client/server auth-state desync, not a failure — the controller must
        // adopt the authenticated state (mirrors iOS "Unexpected server
        // response: error" fix).
        val conn = FakeConnection(autoRespond = { ServerMessage.Error(code = 400, message = "Already authenticated") })
        val controller = SessionController(conn)

        controller.authenticate("tok")

        assertTrue(controller.isAuthenticated)
        assertEquals(conn.generation, controller.authenticatedGeneration)
    }

    @Test
    fun `authenticate surfaces real message on non-400 error`() = runTest {
        // Any other error (rate-limit 429, auth timeout 401, server 500) is a
        // real failure — the actual message must be surfaced, not the "error"
        // type string.
        val conn = FakeConnection(autoRespond = { ServerMessage.Error(code = 429, message = "Too many failed attempts") })
        val controller = SessionController(conn)

        val ex = assertThrows(SessionException::class.java) {
            kotlinx.coroutines.runBlocking { controller.authenticate("tok") }
        }
        assertTrue(ex.message!!.contains("Too many failed attempts"))
        assertFalse(controller.isAuthenticated)
    }

    @Test
    fun `createSession returns id`() = runTest {
        val id = UUID.randomUUID()
        val conn = FakeConnection(autoRespond = { msg ->
            if (msg is ClientMessage.SessionCreate) {
                ServerMessage.SessionCreated(id, cols = 80u, rows = 24u)
            } else {
                null
            }
        })
        val controller = SessionController(conn)

        val result = controller.createSession("my session")

        assertEquals(id, result)
        assertEquals(id, controller.sessionId)
    }

    /**
     * A receive-loop failure nils the socket but does NOT bump the generation, so a
     * generation-only `isAuthValid` reported "authenticated" over a socket that was
     * already gone. The RPC then threw `notConnected` — which `withAuth` does not
     * retry — a silent dead end that showed up as a blank session pane. Auth
     * validity must require a live socket so the handshake reconnects first.
     */
    @Test
    fun `auth validity requires a live socket, not just a matching generation`() = runTest {
        val conn = FakeConnection(autoRespond = { ServerMessage.AuthSuccess(protocolVersion = 1) })
        val controller = SessionController(conn)

        assertFalse(controller.isAuthValid, "never authenticated → invalid")

        controller.authenticate("tok")
        assertTrue(controller.isAuthValid, "authenticated on the current, live connection")

        // The socket died without a generation bump (receive-loop failure).
        conn.isConnected = false
        assertEquals(conn.generation, controller.authenticatedGeneration, "generation still matches")
        assertFalse(controller.isAuthValid, "no live socket → invalid regardless of generation")
    }

    @Test
    fun `attachment validity tracks the connection generation`() = runTest {
        val id = UUID.randomUUID()
        val conn = FakeConnection(autoRespond = { msg ->
            if (msg is ClientMessage.SessionResume) ServerMessage.SessionResumed(id) else null
        })
        val controller = SessionController(conn)

        assertFalse(controller.isAttachmentValid, "no attachment yet")

        controller.resumeSession(id)
        assertTrue(controller.isAttachmentValid, "resume stamps the current generation")
        assertEquals(conn.generation, controller.attachedGeneration)

        // Socket replaced: the server's new handler has no attached PTY, so the
        // stale stamp must invalidate the attachment even though sessionId is set.
        conn.generation += 1
        assertEquals(id, controller.sessionId)
        assertFalse(controller.isAttachmentValid, "generation bump invalidates the attachment")

        // A successful re-resume on the new connection re-validates.
        controller.resumeSession(id)
        assertTrue(controller.isAttachmentValid)
    }

    @Test
    fun `renameSession is fire-and-forget plain send`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)
        val id = UUID.randomUUID()

        controller.renameSession(id, "renamed")

        val sent = conn.sentMessages.single() as ClientMessage.SessionRename
        assertEquals(id, sent.sessionId)
        assertEquals("renamed", sent.name)
    }

    @Test
    fun `response arriving after await suspends resolves exactly once`() = runTest {
        // No autoRespond, so the request suspends at guard.await(). A separate
        // launch delivers the response only after the awaiter has parked.
        val id = UUID.randomUUID()
        val conn = FakeConnection()
        val controller = SessionController(conn)

        var deliveries = 0
        val request = launch {
            val result = controller.createSession("late")
            assertEquals(id, result)
        }
        // Let the request install its subscriber, send, and suspend on await().
        yield()
        runCurrent()
        assertEquals(1, conn.sentMessages.size) { "request should have sent before we deliver" }

        conn.deliver(ServerMessage.SessionCreated(id, cols = 80u, rows = 24u).also { deliveries++ })
        request.join()

        assertEquals(id, controller.sessionId)
        assertEquals(1, deliveries)
    }

    @Test
    fun `duplicate delivery is a no-op and the awaiter returns the first response`() = runTest {
        val firstId = UUID.randomUUID()
        val secondId = UUID.randomUUID()
        val conn = FakeConnection()
        val controller = SessionController(conn)

        val request = launch {
            val result = controller.createSession("dup")
            // First delivery wins; the duplicate must not change the resolved value.
            assertEquals(firstId, result)
        }
        yield()
        runCurrent()

        conn.deliver(ServerMessage.SessionCreated(firstId, cols = 80u, rows = 24u))
        // Second, conflicting response for the SAME request: must be dropped.
        conn.deliver(ServerMessage.SessionCreated(secondId, cols = 80u, rows = 24u))
        request.join()

        assertEquals(firstId, controller.sessionId)
    }

    @Test
    fun `listAllSessions ignores a stray session_list_result from a concurrent request`() = runTest {
        // Regression: cross-device "No Sessions Available". A parallel
        // fetchSessions() (session_list) and this listAllSessions()
        // (session_list_all) run at once; both subscribers used to accept BOTH
        // reply types, so listAllSessions could grab the session_list_result and
        // fail the type check → empty list. It must now match ONLY its own type.
        val conn = FakeConnection()
        val controller = SessionController(conn)

        val wanted = SessionInfo(
            id = UUID.randomUUID(), name = "on-other-device", state = SessionState.ACTIVE_DETACHED,
            tokenId = "other", createdAt = 0.0, cols = 80u, rows = 24u,
        )

        var result: List<SessionInfo>? = null
        val request = launch { result = controller.listAllSessions() }
        yield()
        runCurrent()

        // The other request's reply arrives first — must be ignored here.
        conn.deliver(ServerMessage.SessionList(emptyList()))
        runCurrent()
        assertEquals(null, result) { "listAllSessions must not resolve on session_list_result" }

        // The correct reply resolves it.
        conn.deliver(ServerMessage.SessionListAll(listOf(wanted)))
        request.join()

        assertEquals(listOf(wanted), result)
    }

    @Test
    fun `a session op ignores the handshake replies of a concurrent pass`() = runTest {
        // Regression: the blank-pane-on-relaunch sibling of the "No Sessions
        // Available" bug. A session op (here create) is in flight when the launch
        // handshake runs its own auth_request + session_list. Both of the
        // handshake's replies used to be in the op's accepted set, so whichever
        // landed first resolved the op against a response that was never its own —
        // the op then threw `unexpected`, or worse, silently mis-resolved.
        val id = UUID.randomUUID()
        val conn = FakeConnection()
        val controller = SessionController(conn)

        var result: UUID? = null
        val request = launch { result = controller.createSession("mine") }
        yield()
        runCurrent()

        conn.deliver(ServerMessage.AuthSuccess(protocolVersion = 1))
        conn.deliver(ServerMessage.SessionList(emptyList()))
        runCurrent()
        assertEquals(null, result) { "another request's replies must not resolve createSession" }

        conn.deliver(ServerMessage.SessionCreated(id, cols = 80u, rows = 24u))
        request.join()

        assertEquals(id, result)
    }

    @Test
    fun `resume ignores a No session attached error meant for another request`() = runTest {
        // Regression, mirroring iOS
        // `testResumeIgnoresANoSessionAttachedErrorMeantForAnotherRequest`.
        //
        // A session switch is detach-then-resume, and the incoming terminal lays out
        // and reports its grid while `resume` is still on the wire — the coordinator
        // publishes the new selection before its RPCs, so this is the common path.
        // That `resize` is fire-and-forget, and an OLD server answers it
        // `error(400, "No session attached")` when it lands in the unattached
        // window. With `error` accepted unconditionally the resume waiter took it,
        // the switch failed, and the pane rolled back behind an "Unexpected server
        // response: No session attached" toast. Current servers don't send it at
        // all, but a client can't assume the server has been rebuilt.
        val target = UUID.randomUUID()
        val conn = FakeConnection()
        val controller = SessionController(conn)

        var failure: Throwable? = null
        val request = launch {
            runCatching { controller.resumeSession(target, skipReplay = true) }
                .onFailure { failure = it }
        }
        yield()
        runCurrent()

        // The concurrent fire-and-forget resize's error, from an un-rebuilt server.
        conn.deliver(ServerMessage.Error(code = 400, message = "No session attached"))
        runCurrent()
        assertEquals(null, failure) { "resume must not fail on an error addressed to nobody" }

        conn.deliver(ServerMessage.SessionResumed(target))
        request.join()

        assertEquals(null, failure)
        assertEquals(target, controller.sessionId)
    }

    @Test
    fun `resume still fails on its own error`() = runTest {
        // The narrowness is the safety property. Only this exact message is
        // ignored, and only for waiters it cannot belong to — a resume that
        // genuinely failed answers "Resume failed: …" and must still surface, or a
        // real failure becomes a 10 s timeout that poisons the socket.
        val conn = FakeConnection(
            autoRespond = { ServerMessage.Error(code = 404, message = "Resume failed: sessionNotFound") },
        )
        val controller = SessionController(conn)

        val ex = assertThrows(SessionException::class.java) {
            kotlinx.coroutines.runBlocking { controller.resumeSession(UUID.randomUUID()) }
        }
        assertTrue(ex.message!!.contains("Resume failed"))
    }

    @Test
    fun `detach still fails on No session attached`() = runTest {
        // `detach` is the ONE request for which this error is genuinely addressed —
        // a request-response call with a real waiter, which the server still answers
        // that way when nothing is attached. Filtering it there would hang the
        // waiter to its timeout, which poisons the socket.
        val conn = FakeConnection(
            autoRespond = { ServerMessage.Error(code = 400, message = "No session attached") },
        )
        val controller = SessionController(conn)

        val ex = assertThrows(SessionException::class.java) {
            kotlinx.coroutines.runBlocking { controller.detach() }
        }
        assertTrue(ex.message!!.contains("No session attached"))
    }

    /**
     * Type-scoping shrinks the cross-delivery window but cannot close it, because
     * `error` is a legal reply to EVERY request: two overlapping RPCs always share
     * at least one possible reply type. The controller therefore serializes — at
     * most one request-response RPC outstanding per connection.
     *
     * Proven structurally rather than by outcome: while the first RPC is parked, the
     * second must not even have SENT, so there is no second subscriber for a reply
     * to land in. That is what makes the property hold for `error` too, which no
     * amount of type-scoping can.
     */
    @Test
    fun `a second RPC does not start until the first has answered`() = runTest {
        val id = UUID.randomUUID()
        val conn = FakeConnection()
        val controller = SessionController(conn)

        var listed: List<SessionInfo>? = null
        var created: UUID? = null
        val first = launch { listed = controller.listSessions() }
        yield()
        runCurrent()
        assertEquals(1, conn.sentMessages.size) { "the first RPC should have sent and parked" }

        val second = launch { created = controller.createSession("queued") }
        yield()
        runCurrent()
        assertEquals(
            1, conn.sentMessages.size,
            "the second RPC must wait for the first: no overlapping request on the wire",
        )

        // A reply for the QUEUED request arrives while the first is still outstanding.
        // With one waiter installed it cannot be mis-consumed — and, crucially, an
        // `error` here would not resolve the parked list either.
        conn.deliver(ServerMessage.SessionCreated(id, cols = 80u, rows = 24u))
        runCurrent()
        assertEquals(null, listed) { "session_created must not resolve a parked session_list" }
        assertEquals(null, created) { "the queued RPC hasn't been sent, so it cannot resolve" }

        conn.deliver(ServerMessage.SessionList(emptyList()))
        first.join()
        assertEquals(emptyList<SessionInfo>(), listed)

        // The lock released: the queued RPC now sends and takes its own reply.
        runCurrent()
        assertEquals(2, conn.sentMessages.size) { "the queued RPC sends once the first completes" }
        conn.deliver(ServerMessage.SessionCreated(id, cols = 80u, rows = 24u))
        second.join()
        assertEquals(id, created)
    }

    /**
     * The queue must not be able to strand: a first RPC that never gets an answer
     * releases the lock when its timeout fires, so the one behind it is not stuck
     * on the mutex forever. It does NOT get to run, though — see the desync test
     * below for why. What this test pins is that the queued caller is *released*
     * with an error rather than deadlocked.
     */
    @Test
    fun `a timed-out RPC releases the queue`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)

        var listError: Throwable? = null
        var createError: Throwable? = null
        val first = launch { listError = runCatching { controller.listSessions() }.exceptionOrNull() }
        yield()
        runCurrent()
        val second = launch {
            createError = runCatching { controller.createSession("behind a timeout") }.exceptionOrNull()
        }
        yield()
        runCurrent()
        assertEquals(1, conn.sentMessages.size)

        advanceTimeBy(SessionController.RESPONSE_TIMEOUT_MS + 1)
        first.join()
        second.join()

        assertEquals("The operation timed out.", (listError as SessionException).message)
        assertEquals(
            "The connection to the server needs to be re-established.",
            (createError as SessionException).message,
        ) { "the queued RPC must be released by the mutex, not left waiting on it" }
    }

    /**
     * A timeout retires the waiter but leaves the REQUEST outstanding server-side,
     * so its late reply lands on whichever waiter is installed when it arrives —
     * and without request ids that waiter cannot reject it. Two consecutive
     * `session_list`s is the original bug verbatim: the launch list times out, a
     * post-create list follows, and the late pre-create reply resolves it, so the
     * new session is missing from the sidebar. A timeout therefore poisons the
     * socket until it is replaced.
     */
    @Test
    fun `a timed-out RPC poisons the socket until it is replaced`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)

        var first: Throwable? = null
        val timedOut = launch { first = runCatching { controller.listSessions() }.exceptionOrNull() }
        yield()
        runCurrent()
        advanceTimeBy(SessionController.RESPONSE_TIMEOUT_MS + 1)
        timedOut.join()
        assertEquals("The operation timed out.", (first as SessionException).message)

        // The socket still looks fine to the transport — that is exactly why the
        // controller has to remember, rather than probe.
        assertTrue(conn.isConnected)
        // Fails fast, without suspending on a timer, so it can be awaited inline.
        val refused = runCatching { controller.listSessions() }.exceptionOrNull() as SessionException
        assertEquals("The connection to the server needs to be re-established.", refused.message)
        assertEquals(
            1, conn.sentMessages.size,
            "the refused RPC must never reach the wire, where the late reply could meet it",
        )

        // Replacing the socket clears it, with no explicit reset call: a fresh
        // connection cannot carry the old one's in-flight reply. This is what lets
        // the handshake recover through its existing disconnect + retry path.
        conn.generation += 1
        conn.autoRespond = { ServerMessage.SessionList(emptyList()) }
        assertEquals(emptyList<SessionInfo>(), controller.listSessions()) { "a new generation lifts the poison" }
    }

    /**
     * CANCELLATION abandons an outstanding request exactly as a timeout does: the
     * coroutine goes away, the server still owes a reply, and nobody is waiting for
     * it. Poisoning only on the timeout branch left the original corruption wide
     * open here — the next same-type RPC would consume the abandoned request's
     * reply. This is Kotlin-specific: `withTimeoutOrNull` lets the
     * `CancellationException` escape, whereas Swift's unstructured timeout task
     * survives its caller's cancellation and poisons when it fires.
     */
    @Test
    fun `a cancelled RPC poisons the socket it abandoned a request on`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)

        val abandoned = launch { controller.listSessions() }
        yield()
        runCurrent()
        assertEquals(1, conn.sentMessages.size) { "the request went out and is now outstanding" }

        // Torn-down scope / superseded recovery pass: the caller goes away while the
        // server still owes a reply.
        abandoned.cancel()
        abandoned.join()

        val refused = runCatching { controller.listSessions() }.exceptionOrNull() as SessionException
        assertEquals(SessionController.DESYNC_MESSAGE, refused.message)
        assertEquals(
            1, conn.sentMessages.size,
            "the follow-up must never reach the wire, where the abandoned reply could resolve it",
        )
    }

    /**
     * The poison must name the socket the request went out on, NOT whichever one is
     * current when the timer fires. If a reconnect intervenes, the request died
     * with the old socket and the fresh one can never receive its reply — poisoning
     * the fresh socket would refuse every RPC on a healthy connection until yet
     * another reconnect, and if none came, forever. A worse dead end than the
     * hazard the marker exists to prevent.
     */
    @Test
    fun `a timeout after a reconnect does not poison the fresh socket`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)

        var failure: Throwable? = null
        val inFlight = launch { failure = runCatching { controller.listSessions() }.exceptionOrNull() }
        yield()
        runCurrent()

        // The socket is replaced while the request is still in flight, so its
        // pending reply belongs to a generation that no longer exists...
        conn.generation += 1
        // ...and only THEN does the abandoned request time out.
        advanceTimeBy(SessionController.RESPONSE_TIMEOUT_MS + 1)
        inFlight.join()
        assertEquals("The operation timed out.", (failure as SessionException).message)

        assertFalse(
            controller.isDesynchronized,
            "the replacement socket cannot receive the old socket's reply — it must stay usable",
        )
        conn.autoRespond = { ServerMessage.SessionList(emptyList()) }
        assertEquals(emptyList<SessionInfo>(), controller.listSessions())
    }

    /**
     * A SUCCESSFUL RPC must never poison the socket — checked with real threads,
     * because that is the only setting where it can go wrong.
     *
     * The poison gate asks "was this request answered?", and the answer has to come
     * from the guard's own atomic completion state. The real [RelayConnection]
     * delivers replies on its confinement dispatcher while the awaiter resumes on
     * the caller's, so a flag published *after* the deferred completes can still
     * read as unset on the resumed awaiter's thread — and a request that plainly
     * succeeded would then mark its socket unusable, failing every later RPC until
     * a reconnect. Every other test in this file runs on one dispatcher and cannot
     * observe that at all.
     *
     * Honest about its limits: this is a guard for the property, not a reproducer
     * for the interleaving. The window was two instructions wide, so no stress loop
     * can be relied on to land inside it; the test was validated by widening the
     * window artificially, and it fails immediately when the state is mirrored
     * rather than read from the deferred.
     */
    @Test
    fun `a successful RPC never poisons the socket when the reply comes from another thread`() {
        val deliverOn = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        val callOn = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        try {
            repeat(200) { iteration ->
                val conn = FakeConnection()
                val controller = SessionController(conn)

                runBlocking(callOn) {
                    val rpc = launch { controller.listSessions() }
                    withContext(deliverOn) {
                        // The subscriber is installed before the send, so a recorded
                        // message means the waiter is in place and parked.
                        while (conn.sentMessages.isEmpty()) Thread.yield()
                        conn.deliver(ServerMessage.SessionList(emptyList()))
                    }
                    rpc.join()
                }

                assertFalse(
                    controller.isDesynchronized,
                    "iteration $iteration: an answered RPC poisoned its own socket",
                )
            }
        } finally {
            deliverOn.close()
            callOn.close()
        }
    }

    /**
     * The same poison must invalidate auth, or a caller checking [SessionController.isAuthValid]
     * would skip the handshake and sit on a socket no RPC can use.
     */
    @Test
    fun `a desynchronized socket reports auth invalid`() = runTest {
        val conn = FakeConnection(autoRespond = { ServerMessage.AuthSuccess(protocolVersion = 1) })
        val controller = SessionController(conn)

        controller.authenticate("tok")
        assertTrue(controller.isAuthValid)

        conn.autoRespond = null
        val timedOut = launch { runCatching { controller.listSessions() } }
        yield()
        runCurrent()
        advanceTimeBy(SessionController.RESPONSE_TIMEOUT_MS + 1)
        timedOut.join()

        assertFalse(controller.isAuthValid, "auth over a desynchronized socket is unusable")
        // Still invalid after a reconnect, but now for the ordinary reason (stale
        // generation) — the state that makes the handshake re-authenticate.
        conn.generation += 1
        assertFalse(controller.isAuthValid)
    }

    @Test
    fun `no response hits the timeout path with the expected message`() = runTest {
        // Virtual time: never deliver a response, advance past the 10 s timeout.
        val conn = FakeConnection()
        val controller = SessionController(conn)

        var thrown: Throwable? = null
        val request = launch {
            thrown = runCatching { controller.createSession("never") }.exceptionOrNull()
        }
        yield()
        runCurrent()

        advanceTimeBy(SessionController.RESPONSE_TIMEOUT_MS + 1)
        request.join()

        val ex = thrown as SessionException
        assertEquals("The operation timed out.", ex.message)
    }
}
