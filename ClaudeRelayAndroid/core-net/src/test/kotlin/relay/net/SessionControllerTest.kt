package relay.net

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ClientMessage
import relay.protocol.ServerMessage
import java.util.UUID

/**
 * Test double for [ConnectionSurface]. [autoRespond] feeds a canned server
 * message to the installed subscriber synchronously on `send`, so the "response
 * beats the await" path (the race the real code defends against) is exercised
 * without any real socket or timer.
 */
private class FakeConnection(
    var autoRespond: ((ClientMessage) -> ServerMessage?)? = null,
) : ConnectionSurface {
    override var generation: Long = 7L
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
}

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
}
