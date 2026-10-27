package relay.session

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

/**
 * Pins the overlay copy and the byte formatter. The strings are shared with the
 * Swift `SessionLoadPhase` verbatim, so a drift here is a drift between clients.
 */
class SessionLoadPhaseTest {

    @Test
    fun `labels match the Swift enum`() {
        assertEquals("Connecting to server…", SessionLoadPhase.Connecting.label)
        assertEquals("Authenticating…", SessionLoadPhase.Authenticating.label)
        assertEquals("Loading sessions…", SessionLoadPhase.LoadingSessions.label)
        assertEquals("Attaching to session…", SessionLoadPhase.Attaching.label)
        assertEquals("Loading session history…", SessionLoadPhase.LoadingHistory(0).label)
    }

    @Test
    fun `detail is null except while loading history`() {
        assertNull(SessionLoadPhase.Connecting.detail)
        assertNull(SessionLoadPhase.Authenticating.detail)
        assertNull(SessionLoadPhase.LoadingSessions.detail)
        assertNull(SessionLoadPhase.Attaching.detail)
        assertEquals("212 KB", SessionLoadPhase.LoadingHistory(217_088).detail)
    }

    @Test
    fun `formatBytes boundaries`() {
        assertEquals("<1 KB", SessionLoadPhase.formatBytes(0))
        assertEquals("<1 KB", SessionLoadPhase.formatBytes(1023))
        assertEquals("1 KB", SessionLoadPhase.formatBytes(1024))
        assertEquals("212 KB", SessionLoadPhase.formatBytes(217_088))
        assertEquals("1.2 MB", SessionLoadPhase.formatBytes(1_258_291))
    }
}
