package relay.feature.settings

import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class PreferenceStoreTest {

    private fun store(tmp: File, scope: TestScope) =
        PreferenceStore(File(tmp, "settings.json"), scope)

    @Test
    fun `defaults apply when nothing is stored`(@TempDir tmp: File) = runTest {
        val s = store(tmp, this)
        assertEquals(true, s.boolFlow("missing", true).value)
        assertEquals(42, s.intFlow("missing", 42).value)
        assertEquals("fallback", s.stringFlow("missing", "fallback").value)
        assertEquals(1.5, s.doubleFlow("missing", 1.5).value)
    }

    @Test
    fun `a written value is visible on the flow immediately`(@TempDir tmp: File) = runTest {
        val s = store(tmp, this)
        val flow = s.boolFlow("k", false)
        s.put("k", true)
        assertTrue(flow.value, "the UI must not wait for a disk write to reflect a toggle")
    }

    @Test
    fun `typed flows parse stored strings`(@TempDir tmp: File) = runTest {
        val s = store(tmp, this)
        s.put("i", 7)
        s.put("d", 2.5)
        s.put("b", true)
        s.put("str", "hello")
        assertEquals(7, s.intFlow("i", 0).value)
        assertEquals(2.5, s.doubleFlow("d", 0.0).value)
        assertTrue(s.boolFlow("b", false).value)
        assertEquals("hello", s.stringFlow("str", "").value)
    }

    /**
     * A hand-edited file must not stop the app starting. Any unparseable value
     * degrades to its default.
     */
    @Test
    fun `a malformed value falls back to the default`(@TempDir tmp: File) = runTest {
        File(tmp, "settings.json").writeText("""{"port":"not-a-number"}""")
        val s = store(tmp, this)
        assertEquals(9200, s.intFlow("port", 9200).value)
    }

    @Test
    fun `a corrupt file loads as empty rather than throwing`(@TempDir tmp: File) = runTest {
        File(tmp, "settings.json").writeText("{ not json")
        val s = store(tmp, this)
        assertEquals("default", s.stringFlow("anything", "default").value)
    }

    @Test
    fun `contains reflects whether a key was ever written`(@TempDir tmp: File) = runTest {
        val s = store(tmp, this)
        assertFalse(s.contains("k"))
        s.put("k", "v")
        assertTrue(s.contains("k"))
    }

    @Test
    fun `remove clears the value and reverts the flow to its default`(@TempDir tmp: File) = runTest {
        val s = store(tmp, this)
        s.put("k", "set")
        val flow = s.stringFlow("k", "default")
        assertEquals("set", flow.value)
        s.remove("k")
        assertEquals("default", flow.value)
    }

    @Test
    fun `repeat calls return a flow tracking the same key`(@TempDir tmp: File) = runTest {
        val s = store(tmp, this)
        val a = s.stringFlow("k", "")
        val b = s.stringFlow("k", "")
        s.put("k", "shared")
        assertEquals("shared", a.value)
        assertEquals("shared", b.value, "two readers of one key must see the same value")
    }

    @Test
    fun `mapped flow applies the transform`(@TempDir tmp: File) = runTest {
        val s = store(tmp, this)
        s.put("k", "abc")
        assertEquals("ABC", s.mapped("k") { it?.uppercase() ?: "" }.value)
    }
}

class ShortcutFlagsTest {

    /**
     * `recordingShortcutFlags` is PERSISTED, so these numbers are a wire format
     * shared with the Android client. Re-deriving them from AWT's `InputEvent`
     * masks would make a settings file silently mean a different chord across
     * platforms.
     */
    @Test
    fun `values match android KeyEvent META constants`() {
        assertEquals(0x00001, ShortcutFlags.SHIFT, "android.view.KeyEvent.META_SHIFT_ON")
        assertEquals(0x00002, ShortcutFlags.ALT, "META_ALT_ON")
        assertEquals(0x01000, ShortcutFlags.CTRL, "META_CTRL_ON")
        assertEquals(0x10000, ShortcutFlags.META, "META_META_ON")
    }

    @Test
    fun `default is meta plus alt`() {
        assertEquals(ShortcutFlags.META or ShortcutFlags.ALT, ShortcutFlags.DEFAULT)
    }

    @Test
    fun `mask covers exactly the four tracked modifiers`() {
        assertEquals(0x11003, ShortcutFlags.MASK)
    }

    /** Order follows the Apple HIG so all three clients render an identical chord. */
    @Test
    fun `symbol string orders control option shift command`() {
        val all = ShortcutFlags.CTRL or ShortcutFlags.ALT or ShortcutFlags.SHIFT or ShortcutFlags.META
        assertEquals("⌃⌥⇧⌘", ShortcutFlags.symbolString(all))
    }

    @Test
    fun `symbol string renders the default`() {
        assertEquals("⌥⌘", ShortcutFlags.symbolString(ShortcutFlags.DEFAULT))
    }

    @Test
    fun `symbol string is empty for no modifiers`() {
        assertEquals("", ShortcutFlags.symbolString(0))
    }
}
