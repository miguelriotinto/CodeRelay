package relay.platform

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import relay.net.RelayConnection
import relay.net.SessionController
import relay.protocol.ConnectionConfig
import java.util.UUID

/**
 * End-to-end check against a REAL CodeRelay server.
 *
 * This is the test that proves the shared stack — protocol, transport, session
 * RPC — actually talks to a live relay from the Linux JVM, rather than only
 * passing unit tests. Everything it exercises is code compiled from the Android
 * client's own sources.
 *
 * **Credentials come from the environment, never from the repository.** Set:
 *
 * ```
 * export CODERELAY_TEST_HOST=<relay-host>
 * export CODERELAY_TEST_PORT=9200
 * export CODERELAY_TEST_TOKEN=<token>
 * ```
 *
 * Without them every test here is skipped (JUnit assumption), so CI and other
 * developers are unaffected. A relay token grants full session access to the
 * host machine, so it must not be committed, logged, or echoed — note that
 * nothing below prints the token, only what it unlocked.
 */
class LiveServerIntegrationTest {

    private val host: String? = System.getenv("CODERELAY_TEST_HOST")
    private val port: Int = System.getenv("CODERELAY_TEST_PORT")?.toIntOrNull() ?: 9200
    private val token: String? = System.getenv("CODERELAY_TEST_TOKEN")

    private fun config() = ConnectionConfig(
        id = UUID.randomUUID(),
        name = "integration-test",
        host = host!!,
        port = port.toUShort(),
        useTLS = false,
    )

    private fun requireServer() {
        assumeTrue(!host.isNullOrBlank(), "CODERELAY_TEST_HOST not set — skipping live server test")
        assumeTrue(!token.isNullOrBlank(), "CODERELAY_TEST_TOKEN not set — skipping live server test")
    }

    /**
     * The whole point: connect over a real WebSocket and authenticate with a
     * real token, using the shared `RelayConnection` + `SessionController`.
     */
    @Test
    fun `connects and authenticates against the live relay`() {
        requireServer()
        runBlocking {
            val connection = RelayConnection()
            val controller = SessionController(connection)
            try {
                withTimeout(15_000) {
                    connection.connect(config(), token!!)
                    controller.authenticate(token!!)
                }
                assertTrue(controller.isAuthenticated, "authentication should have succeeded")
            } finally {
                connection.disconnect()
            }
        }
    }

    /** Proves the session-list RPC round-trips and decodes into shared types. */
    @Test
    fun `lists sessions from the live relay`() {
        requireServer()
        runBlocking {
            val connection = RelayConnection()
            val controller = SessionController(connection)
            try {
                withTimeout(20_000) {
                    connection.connect(config(), token!!)
                    controller.authenticate(token!!)
                    val sessions = controller.listSessions()
                    assertNotNull(sessions, "session list must decode")
                    // Session count is whatever the server happens to hold; the
                    // assertion is that the frame decoded into typed models at
                    // all, which is what LiveFrameContractTest pins offline.
                    println("live relay returned ${sessions.size} session(s)")
                    sessions.forEach { println("  - ${it.id} ${it.name.orEmpty()} state=${it.state}") }
                }
            } finally {
                connection.disconnect()
            }
        }
    }

    /**
     * The application-level ping/pong that drives connection-quality reporting
     * and death detection. A null RTT here means the health path is broken even
     * though auth succeeded.
     */
    @Test
    fun `measures ping round-trip time against the live relay`() {
        requireServer()
        runBlocking {
            val connection = RelayConnection()
            val controller = SessionController(connection)
            try {
                withTimeout(20_000) {
                    connection.connect(config(), token!!)
                    controller.authenticate(token!!)
                    val rtt = connection.measurePingRtt()
                    assertNotNull(rtt, "ping must round-trip on a healthy connection")
                    println("live relay ping RTT: ${rtt}ms")
                }
            } finally {
                connection.disconnect()
            }
        }
    }
}
