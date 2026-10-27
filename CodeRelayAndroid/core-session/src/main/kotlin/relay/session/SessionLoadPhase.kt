package relay.session

import java.util.Locale
import kotlin.math.roundToInt

/**
 * Where the client is in the connect → authenticate → list → attach → replay
 * sequence that stands between "the user picked a session" and the first frame
 * of that session on screen. Ported from the Swift `SessionLoadPhase` enum, with
 * the same labels, so the three clients narrate the wait identically.
 *
 * **Why this exists.** On a slow link the terminal pane is plain black for the
 * whole sequence — several seconds — because the client holds the server's
 * ring-buffer replay (up to 512 KB) in `TerminalSessionVm.pendingOutput` and
 * flushes it as ONE frame on `replay_complete`, so nothing at all paints until
 * the very end. That single-frame flush is deliberate (it is what stops history
 * scrolling past), so the fix is not to paint earlier but to say what is
 * happening meanwhile. [SessionCoordinator.sessionLoadPhase] publishes a value
 * of this type for exactly that window and the workspace draws it as a
 * lightweight overlay.
 *
 * [LoadingHistory] is the only phase with a payload: the replay's cumulative
 * byte count, so a 400 KB replay visibly progresses instead of sitting on a
 * static spinner.
 */
sealed class SessionLoadPhase {
    /** Opening (or re-opening) the WebSocket. */
    object Connecting : SessionLoadPhase()

    /** `auth_request` → `auth_success` round trip. */
    object Authenticating : SessionLoadPhase()

    /** `session_list` — asking the server which sessions this token owns. */
    object LoadingSessions : SessionLoadPhase()

    /** The attach / resume / create RPC itself. */
    object Attaching : SessionLoadPhase()

    /** Scrollback replay in flight; [bytes] is the cumulative count buffered so far. */
    data class LoadingHistory(val bytes: Int) : SessionLoadPhase()

    /** The one-line status shown next to the spinner. */
    val label: String
        get() = when (this) {
            Connecting -> "Connecting to server…"
            Authenticating -> "Authenticating…"
            LoadingSessions -> "Loading sessions…"
            Attaching -> "Attaching to session…"
            is LoadingHistory -> "Loading session history…"
        }

    /** Secondary line under [label]: the byte counter while replaying, else nothing. */
    val detail: String?
        get() = (this as? LoadingHistory)?.let { formatBytes(it.bytes) }

    companion object {
        private const val KB = 1024
        private const val MB = KB * 1024

        /**
         * Human-readable size for the replay counter. Coarse on purpose — this
         * ticks several times a second over a 64 KB-framed stream, so a stable
         * unit and no fractional kilobytes keep the text from jittering. Mirrors
         * Swift `SessionLoadPhase.formatBytes`: anything under a kilobyte reads
         * "<1 KB", whole kilobytes below a megabyte, one decimal above.
         */
        fun formatBytes(bytes: Int): String = when {
            bytes < KB -> "<1 KB"
            bytes < MB -> "${(bytes / KB.toDouble()).roundToInt()} KB"
            else -> String.format(Locale.ROOT, "%.1f MB", bytes / MB.toDouble())
        }
    }
}
