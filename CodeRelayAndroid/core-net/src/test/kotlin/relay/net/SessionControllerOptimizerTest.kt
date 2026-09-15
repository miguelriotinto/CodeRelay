package relay.net

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ClientMessage
import relay.protocol.ServerMessage
import java.util.UUID

/**
 * The optimizer half of [SessionController]: capability capture from
 * `auth_success`, the two new RPCs, their status → outcome mapping, and the
 * 20 s waiter that only they use (spec §6, §7.1, §9).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionControllerOptimizerTest {

    private val sessionId: UUID = UUID.fromString("00000000-0000-0000-0000-00000000c0de")

    // MARK: - Protocol version + capabilities

    @Test
    fun `client advertises protocol version 2`() {
        assertEquals(2, ProtocolVersions.CURRENT)
        assertEquals(0, ProtocolVersions.MIN)
    }

    @Test
    fun `optimizer gate is a literal 2 not the client version`() {
        assertEquals(2, PromptOptimizerProtocol.MIN_PROTOCOL_VERSION)
        assertEquals("prompt_optimizer", PromptOptimizerProtocol.CAPABILITY)
    }

    @Test
    fun `auth success stores the server version and capabilities`() = runTest {
        val conn = FakeConnection(autoRespond = {
            ServerMessage.AuthSuccess(protocolVersion = 2, tokenId = "t", capabilities = listOf("prompt_optimizer"))
        })
        val controller = SessionController(conn)
        assertEquals(0, controller.serverProtocolVersion)
        assertEquals(emptySet<String>(), controller.serverCapabilities)

        controller.authenticate("tok")

        assertEquals(2, controller.serverProtocolVersion)
        assertEquals(setOf("prompt_optimizer"), controller.serverCapabilities)
    }

    @Test
    fun `auth success without capabilities yields an empty set`() = runTest {
        val conn = FakeConnection(autoRespond = { ServerMessage.AuthSuccess(protocolVersion = 1) })
        val controller = SessionController(conn)
        controller.authenticate("tok")
        assertEquals(1, controller.serverProtocolVersion)
        assertEquals(emptySet<String>(), controller.serverCapabilities)
    }

    @Test
    fun `resetAuth clears the server version and capabilities`() = runTest {
        val conn = FakeConnection(autoRespond = {
            ServerMessage.AuthSuccess(protocolVersion = 2, capabilities = listOf("prompt_optimizer"))
        })
        val controller = SessionController(conn)
        controller.authenticate("tok")
        controller.resetAuth()
        assertEquals(0, controller.serverProtocolVersion)
        assertEquals(emptySet<String>(), controller.serverCapabilities)
    }

    // MARK: - optimize_prompt

    @Test
    fun `optimizePrompt sends the session id and shareScreen flag`() = runTest {
        val conn = FakeConnection(autoRespond = {
            ServerMessage.OptimizePromptResult(status = "ok", original = "fix bug", prompt = "Fix the bug")
        })
        val controller = SessionController(conn)

        controller.optimizePrompt(sessionId, shareScreen = false)

        val sent = conn.sentMessages.single()
        assertTrue(sent is ClientMessage.OptimizePrompt)
        sent as ClientMessage.OptimizePrompt
        assertEquals(sessionId, sent.sessionId)
        assertEquals(false, sent.shareScreen)
    }

    @Test
    fun `optimizePrompt maps every status`() = runTest {
        val cases: List<Pair<ServerMessage, OptimizeOutcome>> = listOf(
            ServerMessage.OptimizePromptResult(status = "ok", original = "draft", prompt = "Draft") to OptimizeOutcome.Ok("draft"),
            ServerMessage.OptimizePromptResult(status = "ok") to OptimizeOutcome.Ok(null),
            ServerMessage.OptimizePromptResult(status = "no_draft") to OptimizeOutcome.NoDraft,
            ServerMessage.OptimizePromptResult(status = "passthrough") to OptimizeOutcome.Passthrough,
            ServerMessage.OptimizePromptResult(status = "unconfigured") to OptimizeOutcome.Unconfigured,
            ServerMessage.OptimizePromptResult(status = "failed", message = "Prompt too long to optimize") to
                OptimizeOutcome.Failed("Prompt too long to optimize"),
            ServerMessage.OptimizePromptResult(status = "failed") to OptimizeOutcome.Failed(OptimizerStrings.COULD_NOT_REWRITE),
            ServerMessage.OptimizePromptResult(status = "failed", message = "") to OptimizeOutcome.Failed(OptimizerStrings.COULD_NOT_REWRITE),
            ServerMessage.OptimizePromptResult(status = "something_new") to OptimizeOutcome.Failed(OptimizerStrings.COULD_NOT_REWRITE),
        )
        for ((reply, expected) in cases) {
            val controller = SessionController(FakeConnection(autoRespond = { reply }))
            assertEquals(expected, controller.optimizePrompt(sessionId, shareScreen = true), "reply=$reply")
        }
    }

    @Test
    fun `optimizePrompt surfaces an error reply as a SessionException`() = runTest {
        val controller = SessionController(FakeConnection(autoRespond = {
            ServerMessage.Error(code = 401, message = "Not authenticated")
        }))
        val ex = assertThrows(SessionException::class.java) {
            kotlinx.coroutines.runBlocking { controller.optimizePrompt(sessionId, shareScreen = true) }
        }
        assertTrue(ex.isNotAuthenticated)
    }

    @Test
    fun `optimizePrompt ignores a stray session_list_result and waits for its own reply`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)
        var outcome: OptimizeOutcome? = null
        val job = launch { outcome = controller.optimizePrompt(sessionId, shareScreen = true) }
        runCurrent()
        conn.deliver(ServerMessage.SessionList(emptyList()))
        runCurrent()
        assertNull(outcome)
        conn.deliver(ServerMessage.OptimizePromptResult(status = "passthrough"))
        runCurrent()
        assertEquals(OptimizeOutcome.Passthrough, outcome)
        job.join()
    }

    // MARK: - 20 s waiter

    @Test
    fun `optimizePrompt waits past the ordinary 10 s timeout`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)
        var outcome: OptimizeOutcome? = null
        val job = launch { outcome = controller.optimizePrompt(sessionId, shareScreen = true) }
        runCurrent()
        advanceTimeBy(SessionController.RESPONSE_TIMEOUT_MS + 1_000L)
        runCurrent()
        assertNull(outcome, "must still be waiting at 11 s")
        conn.deliver(ServerMessage.OptimizePromptResult(status = "no_draft"))
        runCurrent()
        assertEquals(OptimizeOutcome.NoDraft, outcome)
        job.join()
    }

    @Test
    fun `optimizePrompt times out at 20 s and poisons the socket`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)
        var error: Throwable? = null
        val job = launch {
            try { controller.optimizePrompt(sessionId, shareScreen = true) } catch (e: SessionException) { error = e }
        }
        runCurrent()
        advanceTimeBy(SessionController.OPTIMIZER_TIMEOUT_MS + 1L)
        runCurrent()
        assertNotNull(error)
        assertEquals("The operation timed out.", error!!.message)
        assertTrue(controller.isDesynchronized)
        job.join()
    }

    @Test
    fun `ordinary RPCs still time out at 10 s`() = runTest {
        val conn = FakeConnection()
        val controller = SessionController(conn)
        var error: Throwable? = null
        val job = launch {
            try { controller.listSessions() } catch (e: SessionException) { error = e }
        }
        runCurrent()
        advanceTimeBy(SessionController.RESPONSE_TIMEOUT_MS + 1L)
        runCurrent()
        assertNotNull(error)
        job.join()
    }

    // MARK: - replace_prompt

    @Test
    fun `replacePrompt sends the original text back byte for byte`() = runTest {
        val conn = FakeConnection(autoRespond = { ServerMessage.ReplacePromptResult(status = "ok") })
        val controller = SessionController(conn)
        val original = "fix  the\tbug — café 🚀"

        val outcome = controller.replacePrompt(sessionId, original)

        assertEquals(ReplaceOutcome.Ok, outcome)
        val sent = conn.sentMessages.single() as ClientMessage.ReplacePrompt
        assertEquals(sessionId, sent.sessionId)
        assertEquals(original, sent.text)
    }

    @Test
    fun `replacePrompt maps failed with and without a message`() = runTest {
        assertEquals(
            ReplaceOutcome.Failed("Session not attached"),
            SessionController(FakeConnection(autoRespond = {
                ServerMessage.ReplacePromptResult(status = "failed", message = "Session not attached")
            })).replacePrompt(sessionId, "x"),
        )
        assertEquals(
            ReplaceOutcome.Failed(OptimizerStrings.COULD_NOT_REWRITE),
            SessionController(FakeConnection(autoRespond = { ServerMessage.ReplacePromptResult(status = "failed") }))
                .replacePrompt(sessionId, "x"),
        )
        assertEquals(
            ReplaceOutcome.Failed(OptimizerStrings.COULD_NOT_REWRITE),
            SessionController(FakeConnection(autoRespond = { ServerMessage.ReplacePromptResult(status = "weird") }))
                .replacePrompt(sessionId, "x"),
        )
    }

    // MARK: - Copy

    @Test
    fun `optimizer strings are byte-exact with the spec`() {
        assertEquals("Enable on the relay: claude-relay config set promptOptimizerEnabled true", OptimizerStrings.CONFIG_HINT)
        assertEquals("Update the relay to use the prompt optimizer", OptimizerStrings.UPDATE_RELAY_HINT)
        assertEquals("Type or dictate a prompt first", OptimizerStrings.NO_DRAFT)
        assertEquals("Nothing to optimize", OptimizerStrings.PASSTHROUGH)
        assertEquals("Optimizer could not rewrite this prompt", OptimizerStrings.COULD_NOT_REWRITE)
        assertEquals("Optimized", OptimizerStrings.OPTIMIZED)
        assertEquals("Undo", OptimizerStrings.UNDO)
        assertEquals("Optimize Prompt", OptimizerStrings.WAND_LABEL)
        assertEquals("Share terminal screen with the optimizer", OptimizerStrings.SHARE_SCREEN_TOGGLE)
        assertEquals(
            "With this on, the relay also sends the last 40 lines of the terminal screen to the optimizer model. " +
                "The draft and its working directory are always sent.",
            OptimizerStrings.SHARE_SCREEN_FOOTER,
        )
    }
}
