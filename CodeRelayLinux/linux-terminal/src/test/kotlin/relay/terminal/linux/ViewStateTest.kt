package relay.terminal.linux

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** The renderer's pure input state: wheel banking, click counting, selection geometry. */
class ViewStateTest {

    // ---- WheelBank ----

    @Test
    fun `a classic wheel click is one notch`() {
        val bank = WheelBank()
        assertEquals(1, bank.bank(1f))
        assertEquals(-1, bank.bank(-1f))
    }

    @Test
    fun `trackpad fractions accumulate into whole notches`() {
        val bank = WheelBank()
        assertEquals(0, bank.bank(0.4f))
        assertEquals(0, bank.bank(0.4f))
        assertEquals(1, bank.bank(0.4f), "1.2 banked → one notch, 0.2 carried")
        assertEquals(0, bank.bank(0.5f))
        assertEquals(1, bank.bank(0.4f), "0.2 + 0.5 + 0.4 = 1.1 → the second notch")
    }

    @Test
    fun `reversing direction forgets the carried remainder`() {
        val bank = WheelBank()
        bank.bank(0.9f)
        assertEquals(0, bank.bank(-0.5f), "the 0.9 down is not netted against 0.5 up")
        assertEquals(-1, bank.bank(-0.5f))
    }

    @Test
    fun `zero delta is ignored`() {
        assertEquals(0, WheelBank().bank(0f))
    }

    // ---- PointerState ----

    @Test
    fun `rapid clicks on the same cell count to three and wrap`() {
        val p = PointerState()
        assertEquals(1, p.registerClick(0, 2, 2))
        assertEquals(2, p.registerClick(100, 2, 2))
        assertEquals(3, p.registerClick(200, 2, 2))
        assertEquals(1, p.registerClick(300, 2, 2), "a fourth click starts over")
    }

    @Test
    fun `a slow second click is a single click`() {
        val p = PointerState()
        p.registerClick(0, 2, 2)
        assertEquals(1, p.registerClick(PointerState.MULTI_CLICK_MS + 1, 2, 2))
    }

    @Test
    fun `a click on another cell is a single click`() {
        val p = PointerState()
        p.registerClick(0, 2, 2)
        assertEquals(1, p.registerClick(50, 2, 3))
    }

    // ---- SelectionState ----

    @Test
    fun `a drag past the anchor yields an ordered range`() {
        val s = SelectionState()
        s.begin(3, 5)
        s.extend(1, 2)
        assertEquals(SelectionState.Range(1, 2, 3, 5), s.normalized())
    }

    @Test
    fun `a point selection is not a selection`() {
        val s = SelectionState()
        s.begin(1, 1)
        assertTrue(s.isPoint())
        assertFalse(s.extend(1, 1), "no change")
        assertTrue(s.extend(1, 4))
        assertFalse(s.isPoint())
    }

    @Test
    fun `clear reports whether there was anything to clear`() {
        val s = SelectionState()
        assertFalse(s.clear())
        s.begin(0, 0)
        assertTrue(s.clear())
        assertNull(s.normalized())
    }

    @Test
    fun `line selection spans the whole row`() {
        val s = SelectionState()
        s.selectLine(4, 80)
        assertEquals(SelectionState.Range(4, 0, 4, 80), s.normalized())
    }

    @Test
    fun `columnsOn returns the selected columns per row of a multi-row range`() {
        val r = SelectionState.Range(1, 3, 3, 2)
        assertNull(r.columnsOn(0, 10))
        assertEquals(3 until 10, r.columnsOn(1, 10))
        assertEquals(0 until 10, r.columnsOn(2, 10))
        assertEquals(0 until 2, r.columnsOn(3, 10))
        assertNull(r.columnsOn(4, 10))
    }

    @Test
    fun `columnsOn on a single row with an empty span is null`() {
        assertNull(SelectionState.Range(2, 5, 2, 5).columnsOn(2, 10))
    }

    @Test
    fun `word selection stops at separators and whitespace`() {
        LinuxTerminalEmulator(initialRows = 2, initialCols = 30).use { e ->
            e.feedOutput("foo bar_baz(qux)".toByteArray())
            e.refreshIfDirty()
            val s = SelectionState()
            s.selectWord(e, 0, 5) // inside "bar_baz"
            assertEquals(SelectionState.Range(0, 4, 0, 11), s.normalized())
            assertEquals("bar_baz", s.text(e))

            s.selectWord(e, 0, 12) // "qux" after the paren
            assertEquals("qux", s.text(e))

            s.selectWord(e, 0, 11) // the paren itself
            assertEquals("(", s.text(e))
        }
    }
}
