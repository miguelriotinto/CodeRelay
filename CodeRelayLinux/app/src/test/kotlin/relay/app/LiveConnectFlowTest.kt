package relay.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import relay.net.RelayConnection
import relay.protocol.ConnectionConfig
import relay.session.OwnershipStore
import relay.session.SessionCoordinator
import java.util.UUID
import java.util.concurrent.Executors

/**
 * The connect flow the app's server list drives, end to end against a REAL relay.
 *
 * `LiveServerIntegrationTest` covers the transport (`RelayConnection` +
 * `SessionController`); this covers the layer the UI actually calls — the
 * coordinator's launch handshake and `createNewSession`.
 *
 * **Why this test exists.** `Main.kt` used to build the [ConnectionSession] and
 * show the workspace WITHOUT ever calling `coordinator.connect()`. Every lower
 * layer was green, the server list probed the host as Live, and the workspace
 * still opened on a socket nobody had dialed — so the first session-create fell
 * into the recovery scrim and sat at "Reconnecting…" forever. Nothing below the
 * app module could have caught that. This pins the sequence.
 *
 * Credentials come from the environment, never the repository:
 *
 * ```
 * export CODERELAY_TEST_HOST=<relay-host>
 * export CODERELAY_TEST_PORT=443
 * export CODERELAY_TEST_TLS=1
 * export CODERELAY_TEST_TOKEN=<token>
 * ```
 *
 * Without them the test is skipped, so CI is unaffected. The token is never
 * printed — only what it unlocked.
 */
class LiveConnectFlowTest {

    private val host: String? = System.getenv("CODERELAY_TEST_HOST")
    private val port: Int = System.getenv("CODERELAY_TEST_PORT")?.toIntOrNull() ?: 9200
    private val useTLS: Boolean = System.getenv("CODERELAY_TEST_TLS") == "1"
    private val token: String? = System.getenv("CODERELAY_TEST_TOKEN")

    /** In-memory stand-in for the XDG-backed ownership store. */
    private class FakeOwnership : OwnershipStore {
        private val nameMap = mutableMapOf<UUID, String>()
        private val agentMap = mutableMapOf<UUID, String>()
        override val names: Map<UUID, String> get() = nameMap
        override val agents: Map<UUID, String> get() = agentMap
        override fun setName(id: UUID, name: String?) {
            if (name == null) nameMap.remove(id) else nameMap[id] = name
        }
        override fun setAgent(id: UUID, agentId: String?) {
            if (agentId == null) agentMap.remove(id) else agentMap[id] = agentId
        }
    }

    /**
     * The full path a click on a server row now takes: build the coordinator,
     * run the launch handshake, create a session, then clean up after itself.
     */
    @Test
    fun `connects and creates a session through the coordinator`() {
        assumeTrue(!host.isNullOrBlank(), "CODERELAY_TEST_HOST not set — skipping live connect test")
        assumeTrue(!token.isNullOrBlank(), "CODERELAY_TEST_TOKEN not set — skipping live connect test")

        // The coordinator documents itself as the @MainActor analogue: one
        // confined dispatcher for every entry point. The app uses the AWT event
        // thread; a single-thread executor gives the same confinement headless.
        val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "coordinator") }
        val dispatcher = executor.asCoroutineDispatcher()
        val scope = CoroutineScope(SupervisorJob() + dispatcher)

        val connection = RelayConnection()
        val coordinator = SessionCoordinator(
            scope = scope,
            connection = connection,
            token = token!!,
            ownershipStore = FakeOwnership(),
            config = ConnectionConfig(
                id = UUID.randomUUID(),
                name = "live-connect-test",
                host = host!!,
                port = port.toUShort(),
                useTLS = useTLS,
            ),
            nowMs = { System.nanoTime() / 1_000_000 },
        )

        try {
            runBlocking {
                withContext(dispatcher) {
                    // Throws if the handshake never authenticated — the exact
                    // failure the server list must keep the user out of.
                    withTimeout(30_000) { coordinator.connect() }

                    assertFalse(
                        coordinator.isRecovering.value,
                        "a freshly connected coordinator must not be in recovery",
                    )

                    val before = coordinator.sessions.value.map { it.id }.toSet()
                    withTimeout(30_000) { coordinator.createNewSession() }

                    val active = coordinator.activeSessionId.value
                    assertNotNull(active, "createNewSession must select an active session")
                    assertTrue(
                        active !in before,
                        "the active session must be the newly created one",
                    )
                    assertTrue(
                        coordinator.sessions.value.any { it.id == active },
                        "the new session must appear in the fetched list",
                    )
                    println("live relay created session $active")

                    withTimeout(20_000) { coordinator.terminateSession(active!!) }
                }
            }
        } finally {
            runBlocking { withContext(dispatcher) { runCatching { coordinator.tearDown() } } }
            scope.cancel()
            executor.shutdownNow()
        }
    }
}
