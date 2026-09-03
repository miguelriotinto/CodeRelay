package relay.app

import androidx.compose.ui.input.key.Key
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

/**
 * The accelerator table, and — more importantly — what it must NOT capture.
 *
 * Drives the pure resolver rather than a Compose `KeyEvent`: on Compose Desktop
 * that type is a value class over a skiko-internal event which cannot be
 * constructed outside the toolkit. Splitting the logic out is what makes these
 * invariants testable at all.
 */
class AppShortcutsTest {

    private fun resolve(key: Key, ctrl: Boolean = false, shift: Boolean = false, alt: Boolean = false) =
        AppShortcut.resolve(key, ctrl, shift, alt)

    private fun index(key: Key, ctrl: Boolean = false, alt: Boolean = false) =
        AppShortcut.sessionIndex(key, ctrl, alt)

    // ---- the table ----

    @Test
    fun `ctrl shift T is new session`() =
        assertEquals(AppShortcut.NEW_SESSION, resolve(Key.T, ctrl = true, shift = true))

    @Test
    fun `ctrl shift W is detach`() =
        assertEquals(AppShortcut.DETACH_CURRENT, resolve(Key.W, ctrl = true, shift = true))

    @Test
    fun `ctrl shift Q is terminate`() =
        assertEquals(AppShortcut.TERMINATE_CURRENT, resolve(Key.Q, ctrl = true, shift = true))

    @Test
    fun `ctrl shift B is sidebar toggle`() =
        assertEquals(AppShortcut.TOGGLE_SIDEBAR, resolve(Key.B, ctrl = true, shift = true))

    @Test
    fun `ctrl shift brackets cycle sessions`() {
        assertEquals(AppShortcut.NEXT_SESSION, resolve(Key.RightBracket, ctrl = true, shift = true))
        assertEquals(AppShortcut.PREVIOUS_SESSION, resolve(Key.LeftBracket, ctrl = true, shift = true))
    }

    @Test
    fun `ctrl alt digits select sessions zero-based`() {
        assertEquals(0, index(Key.One, ctrl = true, alt = true))
        assertEquals(8, index(Key.Nine, ctrl = true, alt = true))
    }

    // ---- what must reach the terminal ----

    /**
     * The single most damaging thing a terminal app can get wrong: if Ctrl+C is
     * an app command, the agent cannot be interrupted.
     */
    @Test
    fun `bare ctrl C is never an app shortcut`() = assertNull(resolve(Key.C, ctrl = true))

    @Test
    fun `bare ctrl D is never an app shortcut`() = assertNull(resolve(Key.D, ctrl = true))

    @Test
    fun `bare ctrl W is never an app shortcut`() =
        assertNull(resolve(Key.W, ctrl = true), "Ctrl+W deletes a word in readline")

    /** tmux's prefix key. Stealing it would break tmux inside every session. */
    @Test
    fun `bare ctrl B is never an app shortcut`() = assertNull(resolve(Key.B, ctrl = true))

    @Test
    fun `bare ctrl R is never an app shortcut`() =
        assertNull(resolve(Key.R, ctrl = true), "Ctrl+R is reverse history search")

    @Test
    fun `unmodified letters are never app shortcuts`() {
        assertNull(resolve(Key.T))
        assertNull(resolve(Key.B))
    }

    @Test
    fun `plain digits are not session switches`() = assertNull(index(Key.One))

    @Test
    fun `ctrl digits without alt are not session switches`() =
        assertNull(index(Key.One, ctrl = true), "only Ctrl+Alt+<digit> switches")

    /**
     * Every accelerator must carry Ctrl plus Shift or Alt — the invariant
     * `KeyMapping.isApplicationShortcut` relies on to decide what to forward. A
     * future bare-Ctrl addition would be silently undeliverable.
     */
    @Test
    fun `every resolvable shortcut carries ctrl plus shift or alt`() {
        val candidates = listOf(Key.T, Key.W, Key.Q, Key.B, Key.LeftBracket, Key.RightBracket)
        for (k in candidates) {
            assertNull(resolve(k, ctrl = true), "$k resolved with Ctrl alone — it would never be delivered")
        }
    }
}
