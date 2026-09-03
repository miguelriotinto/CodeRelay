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
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import relay.net.RelayConnection
import relay.protocol.ClientMessage
import relay.protocol.ConnectionConfig
import relay.session.OwnershipStore
import relay.session.SessionCoordinator
import relay.terminal.RelayTerminalController
import relay.terminal.TerminalSessionVm
import relay.terminal.linux.LinuxTerminalEmulator
import relay.terminal.linux.LinuxTerminalEngine
import java.util.UUID
import java.util.concurrent.Executors

/**
 * The three pane transitions that have each shipped blank at some point:
 * creating a second session, switching back to the first, and the name-tap
 * reload. All three end in "the pane shows what the shell is showing", and all
 * three are only observable end to end — the failures were never in one layer.
 *
 * Mounts a pane the way `TerminalHost` does (emulator + engine + controller,
 * then a first `reportSize` standing in for layout), because that first size
 * report is what drains the buffered output.
 */
class LivePaneTransitionsTest {
    private val host: String? = System.getenv("CODERELAY_TEST_HOST")
    private val port: Int = System.getenv("CODERELAY_TEST_PORT")?.toIntOrNull() ?: 9200
    private val useTLS: Boolean = System.getenv("CODERELAY_TEST_TLS") == "1"
    private val token: String? = System.getenv("CODERELAY_TEST_TOKEN")

    private class Own : OwnershipStore {
        private val n = mutableMapOf<UUID, String>()
        private val a = mutableMapOf<UUID, String>()
        override val names get() = n
        override val agents get() = a
        override fun setName(id: UUID, name: String?) { if (name == null) n.remove(id) else n[id] = name }
        override fun setAgent(id: UUID, agentId: String?) { if (agentId == null) a.remove(id) else a[id] = agentId }
    }

    /** Everything TerminalHost builds for one session. */
    private class Pane(
        val emulator: LinuxTerminalEmulator,
        val controller: RelayTerminalController,
    )

    private fun mountPane(
        vm: TerminalSessionVm,
        conn: RelayConnection,
        scope: CoroutineScope,
        cols: Int,
        rows: Int,
    ): Pane {
        val emu = LinuxTerminalEmulator(initialRows = 24, initialCols = 80)
        val engine = LinuxTerminalEngine(emu)
        val ctrl = RelayTerminalController(
            engine, vm,
            onInput = { b -> scope.launch { conn.sendBinary(b) } },
            onResize = { c, r ->
                scope.launch { conn.send(ClientMessage.Resize(c.toUShort(), r.toUShort())) }
            },
        )
        ctrl.reportSize(cols, rows)
        return Pane(emu, ctrl)
    }

    private fun Pane.render(): List<String> {
        emulator.refreshIfDirty()
        return emulator.grid.value.lines.map { l -> l.spans.joinToString("") { it.text }.trimEnd() }
            .filter { it.isNotBlank() }
    }

    @Test
    fun `create, switch and reload all leave the pane showing the session`() {
        assumeTrue(!host.isNullOrBlank() && !token.isNullOrBlank(), "no live server")
        val ex = Executors.newSingleThreadExecutor()
        val d = ex.asCoroutineDispatcher()
        val scope = CoroutineScope(SupervisorJob() + d)
        val conn = RelayConnection()
        val co = SessionCoordinator(
            scope = scope, connection = conn, token = token!!, ownershipStore = Own(),
            config = ConnectionConfig(UUID.randomUUID(), "reload-probe", host!!, port.toUShort(), useTLS),
            nowMs = { System.nanoTime() / 1_000_000 },
        )
        val ids = mutableListOf<UUID>()
        try {
            runBlocking {
                withContext(d) {
                    withTimeout(30_000) { co.connect() }

                    // --- Session A ---
                    withTimeout(30_000) { co.createNewSession() }
                    val a = co.activeSessionId.value!!
                    ids += a
                    val paneA = mountPane(co.terminalCache.view(a)!!, conn, scope, 100, 40)
                    delay(2_500)
                    println("---- A after create: ${paneA.render()}")
                    assertTrue(paneA.render().any { it.contains("%") || it.contains("$") },
                        "the first session must render its prompt, got: ${paneA.render()}")

                    // --- Session B (the "second session comes up blank" case) ---
                    withTimeout(30_000) { co.createNewSession() }
                    val b = co.activeSessionId.value!!
                    ids += b
                    val paneB = mountPane(co.terminalCache.view(b)!!, conn, scope, 100, 40)
                    delay(2_500)
                    println("---- B after create: ${paneB.render()}")
                    assertTrue(paneB.render().any { it.contains("%") || it.contains("$") },
                        "a SECOND session must render its prompt too, got: ${paneB.render()}")

                    // --- Switch back to A (mounting a fresh pane, as the UI does) ---
                    withTimeout(30_000) { co.switchToSession(a) }
                    val paneA2 = mountPane(co.terminalCache.view(a)!!, conn, scope, 100, 40)
                    delay(3_000)
                    println("---- A after switch: ${paneA2.render()}")
                    assertTrue(paneA2.render().any { it.contains("%") || it.contains("$") },
                        "switching back must replay the session, got: ${paneA2.render()}")

                    // --- Name-tap reload on A ---
                    // The name tap. The pane may clear behind the fade, but it
                    // MUST come back with content: the coordinator's reload is
                    // what sends the resume, and anything that pre-empts its
                    // `isReloadingFromServer` guard leaves the screen empty.
                    withTimeout(30_000) { co.reloadTerminalFromServer(a) }
                    var reloaded: List<String> = emptyList()
                    repeat(10) {
                        delay(1_000)
                        reloaded = paneA2.render()
                        println("---- A reload +${it + 1}s: ${reloaded.take(2)}")
                        if (reloaded.any { line -> line.contains("%") || line.contains("$") }) return@repeat
                    }
                    assertTrue(reloaded.any { it.contains("%") || it.contains("$") },
                        "the name-tap reload must repaint the session, got: $reloaded")
                }
            }
        } finally {
            runBlocking {
                withContext(d) {
                    ids.forEach { runCatching { co.terminateSession(it) } }
                    runCatching { co.tearDown() }
                }
            }
            scope.cancel(); ex.shutdownNow()
        }
    }
}
