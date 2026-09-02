package relay.platform

import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import relay.net.RelayConnection
import relay.net.SessionController
import relay.protocol.ClientMessage
import relay.protocol.ConnectionConfig
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference

/**
 * Drives a real PTY on a real relay: create a session, attach, type a command,
 * and read the shell's output back.
 *
 * This is the deepest end-to-end path the client has — it exercises the binary
 * frame channel (terminal I/O is raw WebSocket frames, not the envelope
 * protocol), the scrollback replay handshake, and session lifecycle, all
 * through code compiled from the Android client's sources.
 *
 * Credentials come from the environment; see [LiveServerIntegrationTest].
 * Sessions created here are always terminated in a `finally`, so a failed run
 * does not leave orphaned shells on the host.
 */
class LivePtyIntegrationTest {

    private val host: String? = System.getenv("CODERELAY_TEST_HOST")
    private val port: Int = System.getenv("CODERELAY_TEST_PORT")?.toIntOrNull() ?: 9200
    private val token: String? = System.getenv("CODERELAY_TEST_TOKEN")

    private fun config() = ConnectionConfig(
        id = UUID.randomUUID(),
        name = "pty-integration-test",
        host = host!!,
        port = port.toUShort(),
        useTLS = false,
    )

    @Test
    fun `creates a session, runs a command, and reads the output back`() {
        assumeTrue(!host.isNullOrBlank(), "CODERELAY_TEST_HOST not set — skipping")
        assumeTrue(!token.isNullOrBlank(), "CODERELAY_TEST_TOKEN not set — skipping")

        runBlocking {
            val connection = RelayConnection()
            val controller = SessionController(connection)
            val output = StringBuilder()
            val sessionId = AtomicReference<UUID?>(null)

            // Terminal output arrives as raw binary frames, so it is collected
            // here rather than through the envelope subscriber.
            connection.onTerminalOutput = { bytes ->
                synchronized(output) { output.append(String(bytes, Charsets.UTF_8)) }
            }

            try {
                withTimeout(45_000) {
                    connection.connect(config(), token!!)
                    controller.authenticate(token!!)

                    val id = controller.createSession(name = "linux-client-probe", cols = 80u, rows = 24u)
                    sessionId.set(id)
                    println("created session $id")

                    controller.attachSession(id)
                    println("attached")

                    // Let the shell start and the replay handshake settle before
                    // typing; input sent mid-replay can land before the prompt.
                    delay(2_000)

                    // A marker unlikely to appear in a prompt or MOTD, so the
                    // assertion cannot pass on incidental output.
                    val marker = "CODERELAY_LINUX_OK_${System.nanoTime()}"
                    connection.sendBinary("echo $marker\n".toByteArray())

                    // Poll rather than sleep a fixed time: a loaded host can take
                    // a moment, and a fixed sleep either flakes or wastes time.
                    var seen = false
                    repeat(40) {
                        delay(250)
                        val soFar = synchronized(output) { output.toString() }
                        // The echoed COMMAND also contains the marker, so require
                        // it twice: once as typed, once as the shell's output.
                        if (soFar.split(marker).size > 2) {
                            seen = true
                            return@repeat
                        }
                    }

                    val transcript = synchronized(output) { output.toString() }
                    println("--- received ${transcript.length} bytes of PTY output ---")
                    println(transcript.takeLast(400))

                    assertTrue(
                        seen,
                        "expected the shell to echo back $marker; got ${transcript.length} bytes",
                    )
                }
            } finally {
                // Always clean up: an orphaned session holds a PTY and a
                // RingBuffer on the user's machine for the life of the server.
                // Termination is fire-and-forget on the wire — SessionController
                // exposes no RPC for it because the server sends no reply (see the
                // unattached-request reply rule in SessionRequestHandlers.swift),
                // so it goes out as a raw ClientMessage.
                sessionId.get()?.let { id ->
                    try {
                        withTimeout(10_000) { connection.send(ClientMessage.SessionTerminate(id)) }
                        println("terminated session $id")
                    } catch (e: Exception) {
                        println("WARNING: could not terminate $id: ${e.message}")
                    }
                }
                connection.disconnect()
            }
        }
    }
}
