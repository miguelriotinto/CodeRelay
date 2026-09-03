package relay.app

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Real Unix domain sockets in a temp directory: the first claim binds, the
 * second forwards its argv and reports [SingleInstance.Claim.Forwarded], and
 * a stale socket file does not block a fresh primary.
 */
class SingleInstanceTest {

    @TempDir
    lateinit var dir: File

    private fun socket() = File(dir, "coderelay.sock")

    @Test
    fun `the first launch becomes primary`() {
        val claim = SingleInstance(socket()).claim(emptyList())
        assertInstanceOf(SingleInstance.Claim.Primary::class.java, claim)
        (claim as SingleInstance.Claim.Primary).server.close()
    }

    @Test
    fun `a second launch forwards its argv to the primary and is told to exit`() {
        val primary = SingleInstance(socket()).claim(emptyList()) as SingleInstance.Claim.Primary
        val pool = Executors.newSingleThreadExecutor()
        try {
            val received = pool.submit<List<String>> {
                SingleInstance.readLaunch(primary.server.accept())
            }
            val second = SingleInstance(socket()).claim(listOf("--new-session", "coderelay://session/abc"))
            assertEquals(SingleInstance.Claim.Forwarded, second)
            assertEquals(listOf("--new-session", "coderelay://session/abc"), received.get(5, TimeUnit.SECONDS))
        } finally {
            pool.shutdownNow()
            primary.server.close()
        }
    }

    @Test
    fun `a stale socket file from a crash is replaced by a new primary`() {
        val stale = SingleInstance(socket()).claim(emptyList()) as SingleInstance.Claim.Primary
        stale.server.close() // the file is left behind, nobody listens
        assertTrue(socket().exists())

        val claim = SingleInstance(socket()).claim(emptyList())
        assertInstanceOf(SingleInstance.Claim.Primary::class.java, claim)
        (claim as SingleInstance.Claim.Primary).server.close()
    }

    @Test
    fun `release removes the socket file`() {
        val instance = SingleInstance(socket())
        val claim = instance.claim(emptyList()) as SingleInstance.Claim.Primary
        claim.server.close()
        instance.release()
        assertFalse(socket().exists())
    }

    @Test
    fun `encode and decode round-trip and strip embedded newlines`() {
        val args = listOf("a", "b\nc", "")
        assertEquals(listOf("a", "bc"), SingleInstance.decode(SingleInstance.encode(args)))
    }
}
