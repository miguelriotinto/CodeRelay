package relay.platform

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Follows the Omarchy theme live, so `omarchy theme set` re-colours the
 * terminal and the chrome without a restart (spec §7.1).
 *
 * Polls the modification time of `colors.toml` rather than registering a
 * `WatchService`: Omarchy swaps the theme by re-pointing a symlink
 * (`~/.local/state/omarchy/current/theme`), and inotify on the *old* target
 * never fires for that — the directory entry changed, not the file. A two-second
 * stat of one path is the same cost as the connectivity poll and cannot miss.
 *
 * [palette] is null on a non-Omarchy desktop and stays null; the caller then
 * keeps `TerminalPalette`'s built-in colours. A theme that becomes unreadable
 * mid-flight (half-written file during a switch) keeps the LAST good palette
 * rather than flashing to the defaults — the next poll picks up the finished
 * file.
 */
class OmarchyThemeWatcher(
    scope: CoroutineScope,
    private val pollInterval: Long = DEFAULT_POLL_MILLIS,
    private val load: () -> OmarchyTheme.Palette? = OmarchyTheme::load,
    private val stamp: () -> Long = { OmarchyTheme.colorsFile.lastModified() },
) {

    private val _palette = MutableStateFlow(load())
    val palette: StateFlow<OmarchyTheme.Palette?> = _palette.asStateFlow()

    private var lastStamp: Long = stamp()

    private val job: Job = scope.launch(Dispatchers.IO) {
        while (isActive) {
            delay(pollInterval)
            poll()
        }
    }

    /** One poll step. Exposed for tests; the loop calls it on [pollInterval]. */
    internal fun poll() {
        val now = stamp()
        if (now == lastStamp) return
        lastStamp = now
        // The symlink swap may land before the new colors.toml is complete;
        // keep the last good palette on a parse failure.
        load()?.let { _palette.value = it }
    }

    fun stop() = job.cancel()

    companion object {
        const val DEFAULT_POLL_MILLIS = 2_000L
    }
}
