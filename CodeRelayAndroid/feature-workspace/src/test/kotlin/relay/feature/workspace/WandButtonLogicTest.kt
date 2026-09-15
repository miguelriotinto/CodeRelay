package relay.feature.workspace

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.feature.workspace.WandButtonLogic.WandVisual
import relay.session.OptimizerAvailability
import relay.session.OptimizerState
import relay.session.OptimizerUndo
import java.util.UUID

/**
 * The wand's pure state → visual mapping (spec §7.1): disabled while optimizing /
 * recovering / with no session, dimmed-but-tappable when the relay lacks the
 * optimizer, and the Undo chip only for the session that was optimized, plus the
 * overlay's content decision (a notice and the chip coexist). The Composable
 * rendering itself is compile-only here; these functions are what the overlay
 * reads.
 */
class WandButtonLogicTest {

    private val sessionA = UUID.randomUUID()
    private val sessionB = UUID.randomUUID()

    // MARK: - visual()

    @Test
    fun `ready when available, idle, session active, not recovering`() {
        assertEquals(
            WandVisual.READY,
            WandButtonLogic.visual(OptimizerAvailability.AVAILABLE, OptimizerState.IDLE, hasActiveSession = true, isRecovering = false),
        )
    }

    @Test
    fun `optimizing wins over everything else`() {
        assertEquals(
            WandVisual.OPTIMIZING,
            WandButtonLogic.visual(OptimizerAvailability.UNCONFIGURED, OptimizerState.OPTIMIZING, hasActiveSession = false, isRecovering = true),
        )
    }

    @Test
    fun `disabled with no active session even when available`() {
        assertEquals(
            WandVisual.DISABLED,
            WandButtonLogic.visual(OptimizerAvailability.AVAILABLE, OptimizerState.IDLE, hasActiveSession = false, isRecovering = false),
        )
    }

    @Test
    fun `disabled while recovering even when available`() {
        assertEquals(
            WandVisual.DISABLED,
            WandButtonLogic.visual(OptimizerAvailability.AVAILABLE, OptimizerState.IDLE, hasActiveSession = true, isRecovering = true),
        )
    }

    @Test
    fun `dimmed when the relay is too old`() {
        assertEquals(
            WandVisual.DIMMED,
            WandButtonLogic.visual(OptimizerAvailability.SERVER_TOO_OLD, OptimizerState.IDLE, hasActiveSession = true, isRecovering = false),
        )
    }

    @Test
    fun `dimmed when the relay has no optimizer configured`() {
        assertEquals(
            WandVisual.DIMMED,
            WandButtonLogic.visual(OptimizerAvailability.UNCONFIGURED, OptimizerState.IDLE, hasActiveSession = true, isRecovering = false),
        )
    }

    @Test
    fun `dimmed before the first auth_success (availability unknown)`() {
        // UNKNOWN reads as "not advertised yet" — the tap shows nothing (Task 2's
        // wandHint is null for UNKNOWN), but the button must not claim readiness.
        assertEquals(
            WandVisual.DIMMED,
            WandButtonLogic.visual(OptimizerAvailability.UNKNOWN, OptimizerState.IDLE, hasActiveSession = true, isRecovering = false),
        )
    }

    @Test
    fun `no-session beats dimmed`() {
        // Priority: OPTIMIZING > DISABLED > DIMMED > READY.
        assertEquals(
            WandVisual.DISABLED,
            WandButtonLogic.visual(OptimizerAvailability.SERVER_TOO_OLD, OptimizerState.IDLE, hasActiveSession = false, isRecovering = false),
        )
    }

    // MARK: - undoChipVisible()

    @Test
    fun `chip hidden when there is no undo`() {
        assertFalse(WandButtonLogic.undoChipVisible(null, sessionA))
    }

    @Test
    fun `chip visible for the session that was optimized`() {
        assertTrue(WandButtonLogic.undoChipVisible(OptimizerUndo(sessionA, "original"), sessionA))
    }

    @Test
    fun `chip hidden for a different active session`() {
        assertFalse(WandButtonLogic.undoChipVisible(OptimizerUndo(sessionA, "original"), sessionB))
    }

    @Test
    fun `chip hidden when no session is active`() {
        assertFalse(WandButtonLogic.undoChipVisible(OptimizerUndo(sessionA, "original"), null))
    }

    // MARK: - isTappable()

    @Test
    fun `ready and dimmed are tappable, disabled and optimizing are not`() {
        assertTrue(WandButtonLogic.isTappable(WandVisual.READY))
        assertTrue(WandButtonLogic.isTappable(WandVisual.DIMMED))
        assertFalse(WandButtonLogic.isTappable(WandVisual.DISABLED))
        assertFalse(WandButtonLogic.isTappable(WandVisual.OPTIMIZING))
    }

    // MARK: - overlayContent()

    @Test
    fun `a notice never hides the undo chip`() {
        // The regression this pins: the notice and the undo run on independent
        // timers (4 s vs 10 s, started at different moments), so suppressing the
        // chip behind a late toast could retire the 10 s window unseen and throw
        // away the user's pre-optimize draft.
        val content = WandButtonLogic.overlayContent(notice = "Optimizer unavailable", undoVisible = true)
        assertEquals("Optimizer unavailable", content.notice)
        assertTrue(content.showUndo)
    }

    @Test
    fun `notice only`() {
        val content = WandButtonLogic.overlayContent(notice = "Nothing to optimize", undoVisible = false)
        assertEquals("Nothing to optimize", content.notice)
        assertFalse(content.showUndo)
    }

    @Test
    fun `undo only`() {
        val content = WandButtonLogic.overlayContent(notice = null, undoVisible = true)
        assertNull(content.notice)
        assertTrue(content.showUndo)
    }

    @Test
    fun `neither`() {
        val content = WandButtonLogic.overlayContent(notice = null, undoVisible = false)
        assertNull(content.notice)
        assertFalse(content.showUndo)
    }

    // MARK: - stateDescription()

    @Test
    fun `only optimizing and disabled announce a state`() {
        assertEquals("Optimizing", WandButtonLogic.stateDescription(WandVisual.OPTIMIZING))
        assertEquals("Unavailable", WandButtonLogic.stateDescription(WandVisual.DISABLED))
        assertNull(WandButtonLogic.stateDescription(WandVisual.READY))
        assertNull(WandButtonLogic.stateDescription(WandVisual.DIMMED))
    }
}
