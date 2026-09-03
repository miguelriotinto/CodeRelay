package relay.platform

import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Delivers desktop notifications through `notify-send` (libnotify), which any
 * `org.freedesktop.Notifications` daemon serves — including Omarchy's shell.
 *
 * Chosen over a JVM D-Bus binding deliberately: `notify-send` is present on
 * every target desktop, adds no dependency, and cannot break the app if the
 * notification daemon is missing.
 *
 * ### Click-to-focus without D-Bus
 *
 * libnotify ≥ 0.7.10 (`notify-send --action=KEY=Label`) keeps the process alive
 * until the notification is acted on or dismissed, and prints the chosen action
 * key on stdout. That is enough to route a click back to the session without
 * holding a D-Bus connection: [onActivated] fires with the session id when the
 * output is `default`. A daemon that does not support actions simply never
 * prints one and the process exits with the popup.
 *
 * ### Threading
 *
 * The caller is the session coordinator, which is confined to the AWT event
 * thread. A `notify-send` waiting for a click blocks for the popup's lifetime,
 * so every launch runs on a private daemon thread pool — never on the caller.
 * Every failure is swallowed: a missing daemon must never take down a session.
 */
class DesktopNotifier(
    private val appName: String = "CodeRelay",
    private val onActivated: (UUID) -> Unit = {},
    private val exec: (List<String>) -> String? = ::runAndReadAction,
) : ActivityNotifier.Sender {

    private val pool = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "coderelay-notify").apply { isDaemon = true }
    }

    override fun notify(title: String, body: String, sessionId: UUID, urgent: Boolean) {
        val command = command(title, body, sessionId, urgent)
        pool.execute {
            val action = runCatching { exec(command) }.getOrNull()
            if (action == ACTION_OPEN) runCatching { onActivated(sessionId) }
        }
    }

    /** The argv, split out so the exact flags are unit-tested without a daemon. */
    internal fun command(title: String, body: String, sessionId: UUID, urgent: Boolean): List<String> =
        buildList {
            add("notify-send")
            add("--app-name=$appName")
            add("--urgency=${if (urgent) "critical" else "normal"}")
            // Replaces an earlier notification for the SAME session rather than
            // stacking, so a chatty agent cannot bury the rest of the desktop.
            add("--hint=string:x-canonical-private-synchronous:coderelay-$sessionId")
            add("--icon=utilities-terminal")
            // The click target. Printed back on stdout when chosen.
            add("--action=$ACTION_OPEN=Open")
            // `--` so a title or session name beginning with '-' is not parsed
            // as an option. Session names are user-supplied.
            add("--")
            add(title)
            add(body)
        }

    companion object {
        /** The action key `notify-send` prints when the notification is clicked. */
        const val ACTION_OPEN = "default"

        /**
         * Runs the command and returns the first line of stdout, or null.
         *
         * Bounded at ten minutes: a critical-urgency popup can sit on screen
         * until dismissed, and the thread waiting on it is a daemon thread, so
         * the bound only guards against a daemon that never closes the stream.
         */
        private fun runAndReadAction(command: List<String>): String? {
            val process = ProcessBuilder(command)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start()
            process.outputStream.close()
            val output = process.inputStream.bufferedReader().use { it.readLine() }
            if (!process.waitFor(10, TimeUnit.MINUTES)) process.destroy()
            return output?.trim()?.takeIf { it.isNotEmpty() }
        }
    }
}
