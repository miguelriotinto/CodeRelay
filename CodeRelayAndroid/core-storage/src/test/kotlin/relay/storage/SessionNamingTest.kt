package relay.storage

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.SessionNamingTheme

class SessionNamingTest {

    @Test fun `picks unused name from theme`() {
        val used = setOf("Jon Snow")
        val name = SessionNaming.pickDefaultName(used, SessionNamingTheme.GAME_OF_THRONES, fallbackIndex = 1)
        assertFalse(name in used)
        assertTrue(name.isNotBlank())
        assertTrue(name in SessionNamingTheme.GAME_OF_THRONES.names)
    }

    @Test fun `falls back to Session fallbackIndex when pool exhausted`() {
        val pool = SessionNamingTheme.VIKING.names.toSet()
        val name = SessionNaming.pickDefaultName(pool, SessionNamingTheme.VIKING, fallbackIndex = 7)
        assertEquals("Session 7", name)
    }
}
