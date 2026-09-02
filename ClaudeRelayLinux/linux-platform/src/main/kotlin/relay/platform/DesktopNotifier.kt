package relay.platform

import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Delivers desktop notifications through `notify-send` (libnotify), which any
 * `org.freedesktop.Notifications` daemon serves — including Omarchy's shell.
 *
 * Chosen over a JVM D-Bus binding deliberately: `notify-send` is present on
 * every target desktop, adds no dependency, and cannot break the app if the
 * notification daemon is missing. The cost is that click-to-focus actions are
 * not available (they need a live D-Bus connection to receive the
 * `ActionInvoked` signal), so the session id travels only in the hint metadata
 * for now. That is a known limitation, recorded rather than hidden.
 *
 * Every failure is swallowed: a missing notification daemon must never take down
 * a terminal session.
 */
class DesktopNotifier(
    private val appName: String = "CodeRelay",
    private val exec: (List<String>) -> Unit = ::runDetached,
) : ActivityNotifier.Sender {

    override fun notify(title: String, body: String, sessionId: UUID, urgent: Boolean) {
        val command = buildList {
            add("notify-send")
            add("--app-name=$appName")
            add("--urgency=${if (urgent) "critical" else "normal"}")
            // Replaces an earlier notification for the SAME session rather than
            // stacking, so a chatty agent cannot bury the rest of the desktop.
            add("--hint=string:x-canonical-private-synchronous:coderelay-$sessionId")
            add("--icon=utilities-terminal")
            // `--` so a title or session name beginning with '-' is not parsed
            // as an option. Session names are user-supplied.
            add("--")
            add(title)
            add(body)
        }
        runCatching { exec(command) }
    }

    companion object {
        /**
         * Fire-and-forget. `notify-send` normally exits immediately, but with a
         * daemon that implements the "wait for the notification to close"
         * behaviour it can block for the lifetime of the popup — so we never
         * wait on it beyond a short bound, and we drain nothing.
         */
        private fun runDetached(command: List<String>) {
            val process = ProcessBuilder(command)
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start()
            process.outputStream.close()
            if (!process.waitFor(5, TimeUnit.SECONDS)) {
                // Left running; it will exit when the popup closes. We simply
                // stop caring, rather than killing a notification the user may
                // still be reading.
                return
            }
        }
    }
}
