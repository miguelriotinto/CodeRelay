package relay.app

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.net.StandardProtocolFamily
import java.net.UnixDomainSocketAddress
import java.nio.channels.SocketChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Real Unix domain sockets in a temp directory: the first claim binds, the
 * second forwards its argv and reports [SingleInstance.Claim.Forwarded], a
 * stale socket file does not block a fresh primary, and a peer that never
 * finishes cannot wedge the reader.
 */
class SingleInstanceTest {

    @TempDir
    lateinit var dir: File

    private fun socket() = File(dir, "coderelay.sock")

    @Test
    fun `the first launch becomes primary`() {
        val instance = SingleInstance(dir)
        val claim = instance.claim(emptyList())
        assertInstanceOf(SingleInstance.Claim.Primary::class.java, claim)
        (claim as SingleInstance.Claim.Primary).server.close()
        instance.release()
    }

    @Test
    fun `a second launch forwards its argv to the primary and is told to exit`() {
        val instance = SingleInstance(dir)
        val primary = instance.claim(emptyList()) as SingleInstance.Claim.Primary
        val pool = Executors.newSingleThreadExecutor()
        try {
            val received = pool.submit<List<String>> {
                SingleInstance.readLaunch(primary.server.accept())
            }
            val second = SingleInstance(dir).claim(listOf("--new-session", "coderelay://session/abc"))
            assertEquals(SingleInstance.Claim.Forwarded, second)
            assertEquals(listOf("--new-session", "coderelay://session/abc"), received.get(5, TimeUnit.SECONDS))
        } finally {
            pool.shutdownNow()
            primary.server.close()
            instance.release()
        }
    }

    @Test
    fun `a stale socket file from a crash is replaced by a new primary`() {
        val crashed = SingleInstance(dir)
        val stale = crashed.claim(emptyList()) as SingleInstance.Claim.Primary
        stale.server.close()
        crashed.release() // the lock goes with the dead process; simulate that
        socket().createNewFile() // ...but a socket path was left behind
        assertTrue(socket().exists())

        val instance = SingleInstance(dir)
        val claim = instance.claim(emptyList())
        assertInstanceOf(SingleInstance.Claim.Primary::class.java, claim)
        (claim as SingleInstance.Claim.Primary).server.close()
        instance.release()
    }

    @Test
    fun `release only removes the socket when this process is the primary`() {
        val primary = SingleInstance(dir)
        val claim = primary.claim(emptyList()) as SingleInstance.Claim.Primary
        try {
            // A non-primary instance (it never claimed) must not unlink the
            // primary's socket on its way out.
            SingleInstance(dir).release()
            assertTrue(socket().exists(), "a bystander's release left the primary's socket alone")
        } finally {
            claim.server.close()
        }
        primary.release()
        assertFalse(socket().exists())
    }

    @Test
    fun `a peer that connects and never sends is dropped by the deadline`() {
        val instance = SingleInstance(dir)
        val primary = instance.claim(emptyList()) as SingleInstance.Claim.Primary
        val pool = Executors.newSingleThreadExecutor()
        try {
            val read = pool.submit<List<String>> { SingleInstance.readLaunch(primary.server.accept()) }
            val hang = SocketChannel.open(StandardProtocolFamily.UNIX)
            hang.connect(UnixDomainSocketAddress.of(socket().toPath()))
            // Never writes, never closes. The reader must still return.
            val result = read.get(SingleInstance.IO_DEADLINE_MS + 2_000, TimeUnit.MILLISECONDS)
            assertEquals(emptyList<String>(), result)
            hang.close()
        } finally {
            pool.shutdownNow()
            primary.server.close()
            instance.release()
        }
    }

    @Test
    fun `encode and decode round-trip and strip embedded newlines`() {
        val args = listOf("a", "b\nc", "")
        assertEquals(listOf("a", "bc"), SingleInstance.decode(SingleInstance.encode(args)))
    }

    @Test
    fun `the fallback directory is never under a world-writable tmp`() {
        // With XDG_RUNTIME_DIR set (the normal case) that directory is used;
        // the assertion here is about the shape of the fallback.
        val fallback = SingleInstance.defaultDirectory()
        assertFalse(fallback.path.startsWith("/tmp/"), "fallback must not be a predictable /tmp path: $fallback")
    }
}
