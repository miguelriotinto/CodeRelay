package relay.app

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.UUID

class LaunchArgsTest {

    private val id: UUID = UUID.fromString("3f2504e0-4f89-11d3-9a0c-0305e82c3301")

    @Test
    fun `no arguments is an empty launch`() {
        val launch = LaunchArgs.parse(emptyArray())
        assertTrue(launch.isEmpty)
        assertFalse(launch.newSession)
    }

    @Test
    fun `the desktop action flag is recognised`() {
        val launch = LaunchArgs.parse(arrayOf("--new-session"))
        assertTrue(launch.newSession)
        assertFalse(launch.isEmpty)
        assertEquals(DeepLink.Unhandled, launch.link)
    }

    @Test
    fun `a link and the flag can travel together`() {
        val launch = LaunchArgs.parse(listOf("--new-session", "coderelay://session/$id"))
        assertTrue(launch.newSession)
        assertEquals(DeepLink.Session(id), launch.link)
    }

    @Test
    fun `unknown arguments are ignored rather than rejected`() {
        val launch = LaunchArgs.parse(arrayOf("--verbose", "coderelay://session/$id"))
        assertEquals(DeepLink.Session(id), launch.link)
    }

    @Test
    fun `a pairing link parses to Pair`() {
        val launch = LaunchArgs.parse(arrayOf("coderelay://pair?host=mac.local&port=9200&tls=0&code=K7QP2M4X"))
        assertInstanceOf(DeepLink.Pair::class.java, launch.link)
    }
}
