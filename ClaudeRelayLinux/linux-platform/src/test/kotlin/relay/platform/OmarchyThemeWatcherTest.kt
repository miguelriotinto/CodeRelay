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

    private fun watcher(load: () -> OmarchyTheme.Palette?, stamp: () -> String): Pair<OmarchyThemeWatcher, CoroutineScope> {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        // A huge interval: the loop never fires; tests drive poll() by hand.
        return OmarchyThemeWatcher(scope, pollInterval = Long.MAX_VALUE / 2, load = load, stamp = stamp) to scope
    }

    @Test
    fun `starts with the current palette`() {
        val (w, scope) = watcher({ palette("tokyo-night") }, { "a:1:10" })
        assertEquals("tokyo-night", w.palette.value?.name)
        scope.cancel()
    }

    @Test
    fun `an unchanged stamp does not reload`() {
        var loads = 0
        val (w, scope) = watcher({ loads++; palette("a") }, { "a:1:10" })
        w.poll()
        w.poll()
        assertEquals(1, loads, "only the initial load")
        scope.cancel()
    }

    @Test
    fun `a new stamp reloads and publishes the new palette`() {
        var stamp = "a:1:10"
        var current = "tokyo-night"
        val (w, scope) = watcher({ palette(current) }, { stamp })
        current = "catppuccin"
        stamp = "b:1:10"
        w.poll()
        assertEquals("catppuccin", w.palette.value?.name)
        scope.cancel()
    }

    @Test
    fun `an unreadable theme mid-switch keeps the last good palette`() {
        var stamp = "a:1:10"
        var current: OmarchyTheme.Palette? = palette("tokyo-night")
        val (w, scope) = watcher({ current }, { stamp })
        val before = w.palette.value
        current = null
        stamp = "b:1:10"
        w.poll()
        assertSame(before, w.palette.value)
        scope.cancel()
    }

    @Test
    fun `two theme files sharing an mtime still produce distinct stamps`() {
        val dir = kotlin.io.path.createTempDirectory("omarchy").toFile()
        val a = java.io.File(dir, "a.toml").apply { writeText("x = 1") }
        val b = java.io.File(dir, "b.toml").apply { writeText("x = 1") }
        b.setLastModified(a.lastModified())
        org.junit.jupiter.api.Assertions.assertNotEquals(
            OmarchyThemeWatcher.stampOf(a), OmarchyThemeWatcher.stampOf(b),
            "the resolved path is part of the stamp",
        )
        dir.deleteRecursively()
    }

    @Test
    fun `no omarchy means null, before and after polling`() {
        val (w, scope) = watcher({ null }, { "" })
        assertNull(w.palette.value)
        w.poll()
        assertNull(w.palette.value)
        scope.cancel()
    }
}
