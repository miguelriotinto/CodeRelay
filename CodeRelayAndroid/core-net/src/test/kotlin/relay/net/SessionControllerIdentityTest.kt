package relay.net

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import relay.protocol.ClientMessage
import relay.protocol.ServerIdentity
import relay.protocol.ServerMessage
import java.util.UUID

class SessionControllerIdentityTest {
    @Test fun authenticateRecordsTheServerIdentityAndResetClearsIt() = runTest {
        val id = UUID.randomUUID()
        val conn = FakeConnection(autoRespond = {
            ServerMessage.AuthSuccess(protocolVersion = 3, tokenId = "t", serverId = id.toString(), serverName = "studio")
        })
        val controller = SessionController(conn)
        controller.authenticate("tok")
        assertEquals(ServerIdentity(id, "studio"), controller.serverIdentity)
        controller.resetAuth()
        assertNull(controller.serverIdentity, "the next relay may be a different one")
    }

    @Test fun authRequestAnnouncesProtocolFour() = runTest {
        val conn = FakeConnection(autoRespond = { ServerMessage.AuthSuccess(protocolVersion = 4) })
        SessionController(conn).authenticate("tok")
        assertEquals(4, (conn.sentMessages.first() as ClientMessage.AuthRequest).protocolVersion)
    }
}
