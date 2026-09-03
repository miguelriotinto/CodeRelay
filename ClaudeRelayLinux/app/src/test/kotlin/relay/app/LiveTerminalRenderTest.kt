package relay.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import relay.net.RelayConnection
import relay.protocol.ClientMessage
import relay.protocol.ConnectionConfig
import relay.session.OwnershipStore
import relay.session.SessionCoordinator
import relay.terminal.RelayTerminalController
import relay.terminal.linux.LinuxTerminalEmulator
import relay.terminal.linux.LinuxTerminalEngine
import relay.terminal.linux.TerminalGrid
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Drives a REAL session through the whole client stack and reads the rendered
 * screen back: connect → create → type a command → libvterm → grid.
 *
 * This is the test that would have caught the blank terminal. It wires exactly
 * what `TerminalHost` wires — `RelayTerminalController` between the session view
 * model and [LinuxTerminalEmulator], with the first `reportSize` standing in for
 * the renderer's first layout — so the output-gating path (`terminalReady()`
 * draining `pendingOutput`) is exercised rather than assumed. Everything above
 * this is Compose drawing the grid it produces.
 *
 * Needs a live relay, same env vars as `LiveConnectFlowTest`; skipped otherwise.
 */
class LiveTerminalRenderTest {

    private val host: String? = System.getenv("CODERELAY_TEST_HOST")
    private val port: Int = System.getenv("CODERELAY_TEST_PORT")?.toIntOrNull() ?: 9200
    private val useTLS: Boolean = System.getenv("CODERELAY_TEST_TLS") == "1"
    private val token: String? = System.getenv("CODERELAY_TEST_TOKEN")

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

    /** Flattens a grid snapshot to plain text, one string per row. */
    private fun TerminalGrid.render(): List<String> =
        lines.map { line -> line.spans.joinToString("") { it.text }.trimEnd() }

    @Test
    fun `creates a session, runs a directory listing, and renders the output`() {
        assumeTrue(!host.isNullOrBlank(), "CODERELAY_TEST_HOST not set — skipping")
        assumeTrue(!token.isNullOrBlank(), "CODERELAY_TEST_TOKEN not set — skipping")

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
                name = "render-test",
                host = host!!,
                port = port.toUShort(),
                useTLS = useTLS,
            ),
            nowMs = { System.nanoTime() / 1_000_000 },
        )

        var sessionId: UUID? = null
        val emulator = LinuxTerminalEmulator(initialRows = 24, initialCols = 80)

        try {
            runBlocking {
                withContext(dispatcher) {
                    withTimeout(30_000) { coordinator.connect() }
                    withTimeout(30_000) { coordinator.createNewSession() }
                    sessionId = coordinator.activeSessionId.value
                    assertNotNull(sessionId, "a session must be active")

                    val vm = coordinator.terminalCache.view(sessionId!!)
                    assertNotNull(vm, "the coordinator must cache a terminal view model")

                    // Exactly TerminalHost's wiring.
                    val engine = LinuxTerminalEngine(emulator)
                    val controller = RelayTerminalController(
                        engine = engine,
                        vm = vm!!,
                        onInput = { bytes -> scope.launch { connection.sendBinary(bytes) } },
                        // The real relay-side resize, exactly as WorkspaceScreen
                        // wires it (`vm.sendResize` → `ClientMessage.Resize`).
                        onResize = { cols, rows ->
                            // Deliberately NOT swallowed: if the send fails, this
                            // test must say so rather than quietly measure 80x24.
                            scope.launch {
                                connection.send(ClientMessage.Resize(cols.toUShort(), rows.toUShort()))
                                println("---- sent resize ${cols}x${rows} ----")
                            }
                        },
                    )
                    // The renderer's first layout: resizes the engine, tells the
                    // server, and drains everything buffered until now.
                    // A size the session was NOT created with, so the assertion
                    // below can only pass if the resize actually reached the PTY.
                    controller.reportSize(100, 40)

                    // The resize is fire-and-forget on its own coroutine, so let
                    // it land before asking the PTY how big it is — otherwise this
                    // races the very message it is testing.
                    delay(1_500)

                    // `stty size` asks the tty itself, which is the only
                    // authority on whether the resize reached the PTY. The marker
                    // keeps the assertion independent of the prompt's shape.
                    connection.sendBinary("stty size; echo RENDER_OK\n".toByteArray())

                    // libvterm is fed from the socket; give the shell a moment.
                    val deadline = System.currentTimeMillis() + 15_000
                    var screen: List<String> = emptyList()
                    while (System.currentTimeMillis() < deadline) {
                        delay(250)
                        emulator.refreshIfDirty()
                        screen = emulator.grid.value.render()
                        if (screen.any { it.contains("RENDER_OK") && !it.contains("echo") }) break
                    }

                    println("---- rendered screen (${emulator.grid.value.cols}x${emulator.grid.value.rows}) ----")
                    screen.filter { it.isNotBlank() }.forEach { println("| $it") }
                    println("---- cursor: ${emulator.grid.value.cursor} ----")

                    assertTrue(
                        screen.any { it.contains("RENDER_OK") && !it.contains("echo") },
                        "the command's own output must reach the rendered grid, got: $screen",
                    )
                    assertTrue(
                        screen.any { it.contains("SILVERWING") || it.contains("%") || it.contains("$") },
                        "the shell prompt must be rendered, got: $screen",
                    )

                    // The PTY must end up the size the renderer measured. When it
                    // does not, the shell wraps and repositions the cursor against
                    // a different width than the grid those bytes land on — a Tab
                    // completion then repaints the prompt on top of itself.
                    assertTrue(
                        screen.any { it.trim() == "40 100" },
                        "the PTY must be the size the renderer measured (stty said: " +
                            "${screen.firstOrNull { it.matches(Regex("""\\d+ \\d+""")) }}). " +
                            "When it is not, the shell wraps and repositions the cursor against a " +
                            "different width than the grid those bytes land on, and a Tab completion " +
                            "repaints the prompt on top of itself.",
                    )

                    withTimeout(15_000) { coordinator.fetchSessions(force = true) }
                    val server = coordinator.sessions.value.first { it.id == sessionId }
                    println("---- session list reports: ${server.cols}x${server.rows} ----")
                }
            }
        } finally {
            runBlocking {
                withContext(dispatcher) {
                    sessionId?.let { id -> runCatching { coordinator.terminateSession(id) } }
                    runCatching { coordinator.tearDown() }
                }
            }
            emulator.close()
            scope.cancel()
            executor.shutdownNow()
        }
    }
}
