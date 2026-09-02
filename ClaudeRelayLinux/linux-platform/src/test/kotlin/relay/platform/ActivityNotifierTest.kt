package relay.platform

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.AgentDetectedState
import java.util.UUID

class ActivityNotifierTest {

    private class FakeSender : ActivityNotifier.Sender {
        data class Sent(val title: String, val body: String, val sessionId: UUID, val urgent: Boolean)

        val sent = mutableListOf<Sent>()
        override fun notify(title: String, body: String, sessionId: UUID, urgent: Boolean) {
            sent += Sent(title, body, sessionId, urgent)
        }
    }

    private val session: UUID = UUID.fromString("11111111-2222-3333-4444-555555555555")
    private val other: UUID = UUID.fromString("99999999-8888-7777-6666-555555555555")

    private fun notifier(
        sender: FakeSender,
        focused: () -> UUID? = { null },
    ) = ActivityNotifier(sender, focused)

    // ---- the two transitions that notify ----

    @Test
    fun `notifies when a working agent becomes blocked`() {
        val s = FakeSender()
        val n = notifier(s)
        n.onActivity(session, "api", AgentDetectedState.WORKING)
        n.onActivity(session, "api", AgentDetectedState.BLOCKED)

        val sent = s.sent.single()
        assertEquals("api", sent.title)
        assertEquals("Needs your input", sent.body)
        assertTrue(sent.urgent, "a blocked agent is waiting on the user; it should be urgent")
    }

    @Test
    fun `notifies when a working agent finishes`() {
        val s = FakeSender()
        val n = notifier(s)
        n.onActivity(session, "build", AgentDetectedState.WORKING)
        n.onActivity(session, "build", AgentDetectedState.IDLE)

        val sent = s.sent.single()
        assertEquals("Finished", sent.body)
        assertTrue(!sent.urgent, "finishing is informational, not urgent")
    }

    // ---- everything else is silent ----

    /**
     * On connect the server replays current state for every session. Treating
     * that as an edge would fire a burst of notifications for work that finished
     * hours ago — the single worst failure mode this class has.
     */
    @Test
    fun `the first state seen for a session never notifies`() {
        val s = FakeSender()
        notifier(s).onActivity(session, "api", AgentDetectedState.BLOCKED)
        assertTrue(s.sent.isEmpty())
    }

    @Test
    fun `a repeated state does not re-notify`() {
        val s = FakeSender()
        val n = notifier(s)
        n.onActivity(session, "api", AgentDetectedState.WORKING)
        n.onActivity(session, "api", AgentDetectedState.BLOCKED)
        n.onActivity(session, "api", AgentDetectedState.BLOCKED)
        assertEquals(1, s.sent.size)
    }

    @Test
    fun `idle to blocked does not notify`() {
        val s = FakeSender()
        val n = notifier(s)
        n.onActivity(session, "api", AgentDetectedState.IDLE)
        n.onActivity(session, "api", AgentDetectedState.BLOCKED)
        assertTrue(s.sent.isEmpty(), "only transitions out of WORKING are news")
    }

    @Test
    fun `starting work does not notify`() {
        val s = FakeSender()
        val n = notifier(s)
        n.onActivity(session, "api", AgentDetectedState.IDLE)
        n.onActivity(session, "api", AgentDetectedState.WORKING)
        assertTrue(s.sent.isEmpty())
    }

    @Test
    fun `losing detection does not notify`() {
        val s = FakeSender()
        val n = notifier(s)
        n.onActivity(session, "api", AgentDetectedState.WORKING)
        n.onActivity(session, "api", AgentDetectedState.UNKNOWN)
        assertTrue(s.sent.isEmpty(), "detection losing track is not worth interrupting the user")
    }

    // ---- suppression ----

    @Test
    fun `suppresses a notification for the session on screen`() {
        val s = FakeSender()
        val n = notifier(s, focused = { session })
        n.onActivity(session, "api", AgentDetectedState.WORKING)
        n.onActivity(session, "api", AgentDetectedState.BLOCKED)
        assertTrue(s.sent.isEmpty(), "the user is already looking at it")
    }

    @Test
    fun `still notifies for a background session while another is focused`() {
        val s = FakeSender()
        val n = notifier(s, focused = { other })
        n.onActivity(session, "api", AgentDetectedState.WORKING)
        n.onActivity(session, "api", AgentDetectedState.BLOCKED)
        assertEquals(1, s.sent.size)
    }

    // ---- state hygiene ----

    @Test
    fun `sessions are tracked independently`() {
        val s = FakeSender()
        val n = notifier(s)
        n.onActivity(session, "a", AgentDetectedState.WORKING)
        n.onActivity(other, "b", AgentDetectedState.WORKING)
        n.onActivity(session, "a", AgentDetectedState.IDLE)

        assertEquals(1, s.sent.size)
        assertEquals(session, s.sent.single().sessionId)
    }

    @Test
    fun `reset means the next state is treated as a first sighting`() {
        val s = FakeSender()
        val n = notifier(s)
        n.onActivity(session, "api", AgentDetectedState.WORKING)
        n.reset()
        n.onActivity(session, "api", AgentDetectedState.BLOCKED)
        assertTrue(s.sent.isEmpty(), "after a reconnect, replayed state must not fire")
    }

    @Test
    fun `forget drops one session only`() {
        val s = FakeSender()
        val n = notifier(s)
        n.onActivity(session, "a", AgentDetectedState.WORKING)
        n.onActivity(other, "b", AgentDetectedState.WORKING)
        n.forget(session)
        n.onActivity(session, "a", AgentDetectedState.IDLE)
        n.onActivity(other, "b", AgentDetectedState.IDLE)

        assertEquals(listOf(other), s.sent.map { it.sessionId })
    }

    // ---- naming ----

    @Test
    fun `falls back to a generic title when the session is unnamed`() {
        val s = FakeSender()
        val n = notifier(s)
        n.onActivity(session, null, AgentDetectedState.WORKING)
        n.onActivity(session, null, AgentDetectedState.IDLE)
        assertEquals("Session", s.sent.single().title)
    }

    @Test
    fun `falls back when the session name is blank`() {
        val s = FakeSender()
        val n = notifier(s)
        n.onActivity(session, "   ", AgentDetectedState.WORKING)
        n.onActivity(session, "   ", AgentDetectedState.IDLE)
        assertEquals("Session", s.sent.single().title)
    }

    /** A throwing notification daemon must never break the activity stream. */
    @Test
    fun `a failing sender does not propagate`() {
        val throwing = object : ActivityNotifier.Sender {
            override fun notify(title: String, body: String, sessionId: UUID, urgent: Boolean) =
                throw RuntimeException("no notification daemon")
        }
        val n = ActivityNotifier(throwing)
        n.onActivity(session, "api", AgentDetectedState.WORKING)
        n.onActivity(session, "api", AgentDetectedState.IDLE)
        // Reaching here without an exception is the assertion.
    }
}
