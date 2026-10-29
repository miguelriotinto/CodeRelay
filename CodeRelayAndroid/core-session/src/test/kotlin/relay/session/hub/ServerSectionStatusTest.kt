package relay.session.hub

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class ServerSectionStatusTest {
    private fun d(
        enabled: Boolean = true, connected: Boolean = true, recovering: Boolean = false,
        handshake: Boolean = false, rejected: Boolean = false,
    ) = ServerSectionStatus.derive(enabled, connected, recovering, handshake, rejected)

    @Test fun derivationTable() {
        assertEquals(ServerSectionStatus.Disabled, d(enabled = false, rejected = true))
        assertEquals(ServerSectionStatus.AuthFailed("Token rejected by the relay"), d(rejected = true, recovering = true))
        assertEquals(ServerSectionStatus.Reconnecting, d(recovering = true, connected = false))
        assertEquals(ServerSectionStatus.Connecting, d(handshake = true))
        assertEquals(ServerSectionStatus.Connecting, d(handshake = true, connected = false))
        assertEquals(ServerSectionStatus.Live, d())
        assertEquals(ServerSectionStatus.Offline, d(connected = false))
    }
}
