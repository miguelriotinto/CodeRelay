package relay.feature.servers

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionConfig
import java.util.UUID

class ServerFormLogicTest {

    @Test
    fun `host validation rejects blank and whitespace`() {
        assertFalse(ServerFormLogic.isHostValid(""))
        assertFalse(ServerFormLogic.isHostValid("   "))
        assertTrue(ServerFormLogic.isHostValid("192.168.1.10"))
        assertTrue(ServerFormLogic.isHostValid("host.local"))
    }

    @Test
    fun `port parsing accepts 1 through 65535 and rejects the rest`() {
        assertEquals(1.toUShort(), ServerFormLogic.parsePort("1"))
        assertEquals(9200.toUShort(), ServerFormLogic.parsePort("9200"))
        assertEquals(65535.toUShort(), ServerFormLogic.parsePort("65535"))
        assertNull(ServerFormLogic.parsePort("0"))
        assertNull(ServerFormLogic.parsePort("65536"))
        assertNull(ServerFormLogic.parsePort(""))
        assertNull(ServerFormLogic.parsePort("abc"))
        assertNull(ServerFormLogic.parsePort("-5"))
    }

    @Test
    fun `buildConfig returns null on invalid host or port`() {
        assertNull(ServerFormLogic.buildConfig(null, "name", "", "9200", false))
        assertNull(ServerFormLogic.buildConfig(null, "name", "host", "0", false))
        assertNotNull(ServerFormLogic.buildConfig(null, "name", "host", "9200", false))
    }

    @Test
    fun `buildConfig falls back to host when name blank`() {
        val config = ServerFormLogic.buildConfig(null, "  ", "myhost", "9200", true)
        assertNotNull(config)
        assertEquals("myhost", config!!.name)
        assertEquals("myhost", config.host)
        assertEquals(9200.toUShort(), config.port)
        assertTrue(config.useTLS)
    }

    @Test
    fun `buildConfig reuses existing id in edit mode and mints fresh in add mode`() {
        val existing = UUID.randomUUID()
        val edited = ServerFormLogic.buildConfig(existing, "n", "h", "9200", false)
        assertEquals(existing, edited!!.id)

        val added = ServerFormLogic.buildConfig(null, "n", "h", "9200", false)
        // A fresh id, not the sentinel from edit mode.
        org.junit.jupiter.api.Assertions.assertNotEquals(existing, added!!.id)
    }

    @Test
    fun `upsert appends a new id`() {
        val a = config("a")
        val b = config("b")
        val result = ServerFormLogic.upsert(listOf(a), b)
        assertEquals(listOf(a, b), result)
    }

    @Test
    fun `upsert replaces in place when id matches`() {
        val id = UUID.randomUUID()
        val original = ConnectionConfig(id = id, name = "old", host = "h1", port = 9200u)
        val updated = ConnectionConfig(id = id, name = "new", host = "h2", port = 9300u)
        val other = config("other")

        val result = ServerFormLogic.upsert(listOf(original, other), updated)

        assertEquals(2, result.size)
        assertEquals("new", result[0].name)
        assertEquals("h2", result[0].host)
        assertEquals(other, result[1]) // order preserved
    }

    @Test
    fun `upsert does not mutate the input list`() {
        val a = config("a")
        val input = listOf(a)
        ServerFormLogic.upsert(input, config("b"))
        assertEquals(listOf(a), input)
    }

    @Test
    fun `enabling TLS swaps the plaintext default to 443`() {
        assertEquals("443", ServerFormLogic.portForTLSChange("9200", useTLS = true))
        assertEquals("443", ServerFormLogic.portForTLSChange("", useTLS = true))
        assertEquals("443", ServerFormLogic.portForTLSChange("  9200  ", useTLS = true))
    }

    @Test
    fun `disabling TLS swaps 443 back to the plaintext default`() {
        assertEquals("9200", ServerFormLogic.portForTLSChange("443", useTLS = false))
        assertEquals("9200", ServerFormLogic.portForTLSChange(" 443 ", useTLS = false))
    }

    @Test
    fun `toggling TLS leaves a custom port untouched`() {
        assertEquals("8443", ServerFormLogic.portForTLSChange("8443", useTLS = true))
        assertEquals("8080", ServerFormLogic.portForTLSChange("8080", useTLS = false))
        // Already on the target default: no-op, not double-swapped.
        assertEquals("443", ServerFormLogic.portForTLSChange("443", useTLS = true))
        assertEquals("9200", ServerFormLogic.portForTLSChange("9200", useTLS = false))
    }

    private fun config(name: String) =
        ConnectionConfig(id = UUID.randomUUID(), name = name, host = "h", port = 9200u)
}
