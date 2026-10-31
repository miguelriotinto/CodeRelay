package relay.session.hub

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import relay.protocol.SessionInfo
import relay.protocol.SessionState
import java.util.UUID

class SessionLossTest {
    private val a = LostSession(UUID.randomUUID(), "A")
    private val b = LostSession(UUID.randomUUID(), "B")
    private val c = LostSession(UUID.randomUUID(), "C")

    private fun info(s: LostSession, state: SessionState, token: String = "mine") = SessionInfo(
        id = s.id, name = s.name, state = state, tokenId = token, createdAt = 0.0,
        cols = 80u, rows = 24u,
    )

    @Test
    fun `lost includes missing and terminal`() {
        val lost = SessionLossClassifier.lost(
            before = listOf(a, b, c),
            owned = listOf(info(a, SessionState.ACTIVE_ATTACHED), info(b, SessionState.EXITED)),
        )
        assertEquals(listOf(b, c), lost)
    }

    @Test
    fun `classify taken vs ended`() {
        var r = SessionLossClassifier.classify(
            listOf(b, c), listOf(info(b, SessionState.ACTIVE_ATTACHED, "other")), "mine")
        assertEquals(listOf(b), r.first)
        assertEquals(listOf(c), r.second)

        r = SessionLossClassifier.classify(
            listOf(b), listOf(info(b, SessionState.ACTIVE_ATTACHED, "mine")), "mine")
        assertEquals(emptyList<LostSession>(), r.first)
        assertEquals(listOf(b), r.second)

        r = SessionLossClassifier.classify(
            listOf(b), listOf(info(b, SessionState.EXITED, "other")), "mine")
        assertEquals(emptyList<LostSession>(), r.first)
        assertEquals(listOf(b), r.second)
    }

    @Test
    fun `classify first duplicate wins`() {
        val r = SessionLossClassifier.classify(
            listOf(b),
            listOf(info(b, SessionState.ACTIVE_ATTACHED, "other"), info(b, SessionState.EXITED, "other")),
            "mine")
        assertEquals(listOf(b), r.first)
    }

    @Test
    fun `classify nil all means taken`() {
        val r = SessionLossClassifier.classify(listOf(a, b), null, "mine")
        assertEquals(listOf(a, b), r.first)
        assertEquals(emptyList<LostSession>(), r.second)
    }

    private fun items(names: List<String>, server: UUID = UUID.randomUUID(), serverName: String = "srv") =
        names.map { SessionLossItem(server, serverName, LostSession(UUID.randomUUID(), it)) }

    @Test
    fun `copy one two many`() {
        assertEquals("Session Moved", SessionLossCopy.takenTitle(1))
        assertEquals("Sessions Moved", SessionLossCopy.takenTitle(2))
        assertEquals("Sessions Moved", SessionLossCopy.takenTitle(0))
        val s = UUID.randomUUID()
        fun i(vararg n: String) = items(n.toList(), s)
        assertEquals("A was attached from another device.", SessionLossCopy.takenBody(i("A")))
        assertEquals("A and B were attached from another device.", SessionLossCopy.takenBody(i("A", "B")))
        assertEquals("A, B and 1 other were attached from another device.", SessionLossCopy.takenBody(i("A", "B", "C")))
        assertEquals("A, B and 2 others were attached from another device.", SessionLossCopy.takenBody(i("A", "B", "C", "D")))
        assertEquals("A ended while you were away.", SessionLossCopy.endedBody(i("A")))
        assertEquals("A and B ended while you were away.", SessionLossCopy.endedBody(i("A", "B")))
        assertEquals("A, B and 1 other ended while you were away.", SessionLossCopy.endedBody(i("A", "B", "C")))
        assertEquals("A, B and 2 others ended while you were away.", SessionLossCopy.endedBody(i("A", "B", "C", "D")))
        assertEquals("", SessionLossCopy.takenBody(emptyList()))
    }

    @Test
    fun `server suffix only when mixed`() {
        val s = UUID.randomUUID()
        assertEquals(
            "Renly and Stannis were attached from another device.",
            SessionLossCopy.takenBody(items(listOf("Renly", "Stannis"), s, "mac-mini")))
        val mixed = listOf(
            SessionLossItem(UUID.randomUUID(), "mac-mini", LostSession(UUID.randomUUID(), "Renly")),
            SessionLossItem(UUID.randomUUID(), "studio", LostSession(UUID.randomUUID(), "Stannis")),
        )
        assertEquals(
            "Renly (on mac-mini) and Stannis (on studio) were attached from another device.",
            SessionLossCopy.takenBody(mixed))
    }
}
