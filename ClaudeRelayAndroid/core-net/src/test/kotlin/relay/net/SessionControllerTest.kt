package relay.net

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
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

/**
 * Test double for [ConnectionSurface]. [autoRespond] feeds a canned server
 * message to the installed subscriber synchronously on `send`, so the "response
 * beats the await" path (the race the real code defends against) is exercised
 * without any real socket or timer. [deliver] feeds the installed subscribers a
 * message out-of-band (after the awaiter has suspended) for the async/duplicate
 * delivery paths.
 */
private class FakeConnection(
    var autoRespond: ((ClientMessage) -> ServerMessage?)? = null,
) : ConnectionSurface {
    override var generation: Long = 7L

    /** Whether a socket is up. Mutable so a test can model the receive-loop
     *  failure that drops the socket WITHOUT bumping [generation]. */
    override var isConnected: Boolean = true
    var sentMessages = mutableListOf<ClientMessage>()
    private val subscribers = LinkedHashMap<UUID, (ServerMessage) -> Unit>()

    override fun addServerMessageSubscriber(handler: (ServerMessage) -> Unit): UUID {
        val id = UUID.randomUUID()
        subscribers[id] = handler
        return id
    }

    override fun removeSubscriber(id: UUID) {
        subscribers.remove(id)
    }

    override suspend fun send(message: ClientMessage) {
        sentMessages.add(message)
        autoRespond?.invoke(message)?.let { response ->
            // Deliver synchronously, mirroring a response that arrives during send.
            subscribers.values.toList().forEach { it(response) }
        }
    }

    /** Fans [response] out to every installed subscriber (out-of-band delivery). */
    fun deliver(response: ServerMessage) {
        subscribers.values.toList().forEach { it(response) }
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
