package relay.net

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Test
import relay.protocol.ServerMessage

/** Protocol-version capture from `auth_success` and the ordinary 10 s RPC waiter. */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionControllerVersionTest {

    @Test
    fun `client advertises protocol version 4`() {
        assertEquals(4, ProtocolVersions.CURRENT)
        assertEquals(0, ProtocolVersions.MIN)
    }

    @Test
    fun `auth success stores the server version`() = runTest {
        val conn = FakeConnection(autoRespond = { ServerMessage.AuthSuccess(protocolVersion = 2, tokenId = "t") })
        val controller = SessionController(conn)
        assertEquals(0, controller.serverProtocolVersion)

        controller.authenticate("tok")

        assertEquals(2, controller.serverProtocolVersion)
    }

    @Test
    fun `resetAuth clears the server version`() = runTest {
        val conn = FakeConnection(autoRespond = { ServerMessage.AuthSuccess(protocolVersion = 2) })
        val controller = SessionController(conn)
        controller.authenticate("tok")
        controller.resetAuth()
        assertEquals(0, controller.serverProtocolVersion)
    }

    @Test
    fun `ordinary RPCs time out at 10 s`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)
        var error: Throwable? = null
        val job = launch {
            try { controller.listSessions() } catch (e: SessionException) { error = e }
        }
        runCurrent()
        advanceTimeBy(SessionController.RESPONSE_TIMEOUT_MS + 1L)
        runCurrent()
        assertNotNull(error)
        job.join()
    }
}
