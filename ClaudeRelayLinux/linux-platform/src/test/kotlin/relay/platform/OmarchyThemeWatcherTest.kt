package relay.platform

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Test

class OmarchyThemeWatcherTest {

    private fun palette(name: String) = OmarchyTheme.Palette(
        name = name, mode = OmarchyTheme.Mode.DARK, ansi = IntArray(16), background = 0, foreground = 0,
        accent = 0, selection = 0,
    )

    private fun watcher(load: () -> OmarchyTheme.Palette?, stamp: () -> Long): Pair<OmarchyThemeWatcher, CoroutineScope> {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        // A huge interval: the loop never fires; tests drive poll() by hand.
        return OmarchyThemeWatcher(scope, pollInterval = Long.MAX_VALUE / 2, load = load, stamp = stamp) to scope
    }

    @Test
    fun `starts with the current palette`() {
        val (w, scope) = watcher({ palette("tokyo-night") }, { 1L })
        assertEquals("tokyo-night", w.palette.value?.name)
        scope.cancel()
    }

    @Test
    fun `an unchanged stamp does not reload`() {
        var loads = 0
        val (w, scope) = watcher({ loads++; palette("a") }, { 1L })
        w.poll()
        w.poll()
        assertEquals(1, loads, "only the initial load")
        scope.cancel()
    }

    @Test
    fun `a new stamp reloads and publishes the new palette`() {
        var stamp = 1L
        var current = "tokyo-night"
        val (w, scope) = watcher({ palette(current) }, { stamp })
        current = "catppuccin"
        stamp = 2L
        w.poll()
        assertEquals("catppuccin", w.palette.value?.name)
        scope.cancel()
    }

    @Test
    fun `an unreadable theme mid-switch keeps the last good palette`() {
        var stamp = 1L
        var current: OmarchyTheme.Palette? = palette("tokyo-night")
        val (w, scope) = watcher({ current }, { stamp })
        val before = w.palette.value
        current = null
        stamp = 2L
        w.poll()
        assertSame(before, w.palette.value)
        scope.cancel()
    }

    @Test
    fun `no omarchy means null, before and after polling`() {
        val (w, scope) = watcher({ null }, { 0L })
        assertNull(w.palette.value)
        w.poll()
        assertNull(w.palette.value)
        scope.cancel()
    }
}
