package relay.platform

import relay.protocol.AgentDetectedState
import java.util.UUID

/**
 * Raises desktop notifications when an agent finishes or needs input.
 *
 * **This replaces push entirely — it does not port it.** The server speaks APNs
 * and FCM, neither of which a Linux desktop app can receive, and adding a third
 * provider would be real server work. It is unnecessary: push exists because
 * mobile operating systems suspend the app. A desktop client holds its WebSocket
 * open, and the server already streams `session_activity` to every connected
 * client for the token — the same signal `PushDispatcher` watches server-side to
 * decide a push is warranted. We notify from the stream we are already receiving.
 *
 * Consequences: no Firebase project, no `google-services.json`, no new secrets on
 * the Mac, no server change at all, and notifications work even when the server's
 * `pushEnabled` is false (the default).
 *
 * The edge detection here is deliberately pure and separated from delivery
 * ([Sender]) so the interesting behaviour — which transitions notify, which are
 * suppressed — is unit-tested without a notification daemon.
 */
class ActivityNotifier(
    private val sender: Sender,
    /**
     * Returns the session the user is currently looking at, or null when the
     * window is unfocused. Notifying about the session already on screen is pure
     * noise, so that case is suppressed.
     */
    private val focusedSession: () -> UUID? = { null },
) {

    /** Delivery seam. Production uses [DesktopNotifier]; tests use a fake. */
    interface Sender {
        fun notify(title: String, body: String, sessionId: UUID, urgent: Boolean)
    }

    /** Last state seen per session, so we notify on edges rather than on every message. */
    private val lastState = mutableMapOf<UUID, AgentDetectedState>()

    /**
     * Feeds one `session_activity` update in.
     *
     * Notifies on exactly two transitions, mirroring the server's own rules:
     *  - `WORKING → BLOCKED` — the agent is asking the user something.
     *  - `WORKING → IDLE`    — the agent finished.
     *
     * Everything else is silent. In particular the FIRST state seen for a
     * session never notifies: on connect the server replays current state for
     * every session, and treating that as an edge would fire a burst of
     * notifications for work that finished hours ago.
     */
    fun onActivity(sessionId: UUID, sessionName: String?, state: AgentDetectedState) {
        val previous = lastState.put(sessionId, state)

        if (previous == null) return
        if (previous == state) return
        if (previous != AgentDetectedState.WORKING) return

        val label = sessionName?.takeIf { it.isNotBlank() } ?: "Session"

        when (state) {
            AgentDetectedState.BLOCKED -> emit(
                title = label,
                body = "Needs your input",
                sessionId = sessionId,
                urgent = true,
            )
            AgentDetectedState.IDLE -> emit(
                title = label,
                body = "Finished",
                sessionId = sessionId,
                urgent = false,
            )
            // WORKING is the state we came from; UNKNOWN means detection lost
            // track, which is not news worth interrupting the user for.
            AgentDetectedState.WORKING, AgentDetectedState.UNKNOWN -> Unit
        }
    }

    /** Drops a session's remembered state, e.g. when it is terminated or stolen. */
    fun forget(sessionId: UUID) {
        lastState.remove(sessionId)
    }

    /** Drops all remembered state — call on disconnect so reconnect does not fire a burst. */
    fun reset() {
        lastState.clear()
    }

    private fun emit(title: String, body: String, sessionId: UUID, urgent: Boolean) {
        // The user is already looking at it; a notification would be noise.
        if (focusedSession() == sessionId) return
        runCatching { sender.notify(title, body, sessionId, urgent) }
    }
}
