package relay.protocol

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.UUID

/**
 * Contract test that round-trips a REAL captured server frame against the wire decoder.
 *
 * The fixture `captured_session_list_result.json` is a verbatim `session_list_result`
 * text frame captured from the running Claude Relay server (ws://127.0.0.1:9200) on
 * 2026-06-08. It is the single most important fidelity test in M1: it proves the
 * Kotlin decoder accepts genuine server output, not just synthetic fixtures.
 *
 * Salient real-world properties this frame locks in:
 *  - `createdAt` is a floating-point NUMBER (802628495.194415 — seconds since the 2001
 *    reference date), NOT an ISO-8601 string. The Swift WebSocket server uses a default
 *    JSONEncoder that emits Double timestamps; the Admin HTTP API uses ISO-8601. These
 *    two paths must never be confused. See CLAUDE.md "Date Encoding Caveat".
 *  - `id` is UPPERCASE on the wire (`99034A11-...`); UUID.fromString is case-insensitive
 *    and must accept it.
 *  - Field order is arbitrary (keyed by name, not position).
 */
class LiveFrameContractTest {
    private fun loadCapturedFrame(): String =
        javaClass.classLoader!!
            .getResource("captured_session_list_result.json")!!
            .readText()

    @Test fun `round-trips the captured live server session_list_result frame`() {
        val frame = loadCapturedFrame()

        val decoded = MessageEnvelope.decodeServer(frame)
        assertTrue(decoded is ServerMessage.SessionList, "expected a SessionList, got $decoded")
        val list = decoded as ServerMessage.SessionList

        assertTrue(list.sessions.isNotEmpty(), "captured frame must carry at least one session")
        assertEquals(1, list.sessions.size)

        val session = list.sessions.single()

        // CRITICAL Double-vs-ISO guard. The server's WebSocket path emits createdAt as a
        // reference-date Double (seconds since 2001). If a future server were to send an
        // ISO-8601 string here instead, ReferenceDateDoubleSerializer would have thrown and
        // decodeServer above would never have reached this line. This assertion (and the
        // isFinite() check) is therefore the canary for an accidental ISO-8601 wire format:
        // if it ever fails, the server changed its date encoding on the WebSocket path.
        assertEquals(802628495.194415, session.createdAt, "createdAt must be the exact reference-date Double")
        assertTrue(session.createdAt.isFinite(), "createdAt must be a finite Double, never NaN/Inf (proves it was decoded as a number, not a string)")

        // Uppercase wire UUID must decode via case-insensitive UUID.fromString.
        assertEquals(UUID.fromString("99034A11-9398-4496-B34D-6CE5A283BB27"), session.id)

        assertEquals(SessionState.ACTIVE_ATTACHED, session.state)
        assertEquals(ActivityState.AGENT_ACTIVE, session.activity)
        assertEquals("claude", session.agent)
        assertEquals("android-contract", session.name)
        assertEquals(80, session.cols.toInt())
        assertEquals(24, session.rows.toInt())
        assertEquals("9c1dfa95", session.tokenId)
    }

    @Test fun `captured createdAt is not parsed as a string-like sentinel`() {
        // Focused regression assertion documenting the Double-vs-ISO guard intent.
        // A maintainer who later sees an ISO-8601 server frame should treat THIS test as
        // the canary: the on-the-wire createdAt is a numeric Double, not a date string.
        val session = (MessageEnvelope.decodeServer(loadCapturedFrame()) as ServerMessage.SessionList)
            .sessions
            .single()

        // 802628495.194415 has a real fractional component; a string-parsed-as-0 or an
        // integer-truncated value would not equal it.
        assertFalse(session.createdAt == 0.0, "createdAt must not collapse to 0.0 (would indicate a failed/string parse)")
        assertTrue(session.createdAt > 802628495.0 && session.createdAt < 802628496.0, "createdAt must retain its sub-second fraction")
    }
}
