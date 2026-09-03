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
import java.io.File
import java.nio.file.Files

/**
 * Follows the Omarchy theme live, so `omarchy theme set` re-colours the
 * terminal and the chrome without a restart (spec §7.1).
 *
 * Polls a *stamp* of the theme rather than registering a `WatchService`:
 * Omarchy swaps the theme by re-pointing a symlink
 * (`~/.local/state/omarchy/current/theme`), and inotify on the *old* target
 * never fires for that — the directory entry changed, not the file. A
 * two-second stat of one path is the same cost as the connectivity poll and
 * cannot miss.
 *
 * The stamp is the symlink's resolved target plus the file's mtime and size,
 * not the mtime alone: two installed themes' `colors.toml` files routinely
 * share a modification time to the millisecond (they were unpacked together),
 * so an mtime-only poll missed a switch between them.
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
    private val stamp: () -> String = { stampOf(OmarchyTheme.colorsFile) },
) {

    private val _palette = MutableStateFlow(load())
    val palette: StateFlow<OmarchyTheme.Palette?> = _palette.asStateFlow()

    private var lastStamp: String = stamp()

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

        /** Resolved path + mtime + size; distinct for any two theme files. */
        internal fun stampOf(file: File): String {
            val target = runCatching { file.toPath().toRealPath().toString() }.getOrDefault(file.path)
            val mtime = runCatching { Files.getLastModifiedTime(file.toPath()).toMillis() }.getOrDefault(0L)
            val size = runCatching { Files.size(file.toPath()) }.getOrDefault(0L)
            return "$target:$mtime:$size"
        }
    }
}
