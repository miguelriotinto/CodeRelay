package relay.feature.workspace

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import relay.net.OptimizerStrings
import relay.session.OptimizerAvailability
import relay.session.OptimizerState
import relay.session.OptimizerUndo
import java.util.UUID

/**
 * Pure state → visual mapping for the magic-wand button (spec §7.1). Kept out of
 * the Composables so it is assertable on the JVM; `WandButton` / `OptimizerOverlay`
 * are thin renderers over it, exactly like `WandButton` in CodeRelayClient over
 * `SharedSessionCoordinator`'s optimizer state.
 */
object WandButtonLogic {

    enum class WandVisual {
        /** No session or recovering — greyed out and not clickable. */
        DISABLED,
        /** Relay lacks the optimizer (or hasn't said yet) — dimmed but clickable; the tap shows the hint. */
        DIMMED,
        /** Optimizer advertised, idle — full colour, clickable. */
        READY,
        /** One RPC in flight — spinner, not clickable. */
        OPTIMIZING,
    }

    /** Priority: OPTIMIZING > DISABLED > DIMMED > READY. */
    fun visual(
        availability: OptimizerAvailability,
        state: OptimizerState,
        hasActiveSession: Boolean,
        isRecovering: Boolean,
    ): WandVisual = when {
        state == OptimizerState.OPTIMIZING -> WandVisual.OPTIMIZING
        !hasActiveSession || isRecovering -> WandVisual.DISABLED
        availability != OptimizerAvailability.AVAILABLE -> WandVisual.DIMMED
        else -> WandVisual.READY
    }

    /** The "Optimized · Undo" chip belongs to the session that was optimized, and only while it is active. */
    fun undoChipVisible(undo: OptimizerUndo?, activeSessionId: UUID?): Boolean =
        undo != null && activeSessionId != null && undo.sessionId == activeSessionId

    /** Whether a tap reaches the coordinator. DIMMED is tappable on purpose: the tap is how the user learns why. */
    fun isTappable(visual: WandVisual): Boolean =
        visual == WandVisual.READY || visual == WandVisual.DIMMED

    /** What sits above the wand. Both halves can be present at once — see [overlayContent]. */
    data class OverlayContent(val notice: String?, val showUndo: Boolean)

    /**
     * The overlay's content decision. A notice does **not** suppress the Undo
     * chip: the two live on independent timers (4 s vs 10 s) that do not start
     * together, so hiding the chip behind a late toast could retire it unseen and
     * the pre-optimize draft — the user's only copy — would be gone. Swift renders
     * both side by side (`WandButton.swift:41-65`); this renders them stacked.
     */
    fun overlayContent(notice: String?, undoVisible: Boolean): OverlayContent =
        OverlayContent(notice = notice, showUndo = undoVisible)

    /**
     * TalkBack state for the wand, or null when the visual carries no state worth
     * announcing (READY, and DIMMED whose explanation is the tap's own toast).
     */
    fun stateDescription(visual: WandVisual): String? = when (visual) {
        WandVisual.OPTIMIZING -> "Optimizing"
        WandVisual.DISABLED -> "Unavailable"
        WandVisual.READY, WandVisual.DIMMED -> null
    }
}

/**
 * The 44 dp magic-wand button. Same footprint the mic button had, so it drops
 * into the same bottom-right slot in `TerminalColumn`.
 */
@Composable
fun WandButton(
    visual: WandButtonLogic.WandVisual,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tappable = WandButtonLogic.isTappable(visual)
    val container = when (visual) {
        WandButtonLogic.WandVisual.READY, WandButtonLogic.WandVisual.OPTIMIZING ->
            MaterialTheme.colorScheme.primaryContainer
        WandButtonLogic.WandVisual.DIMMED, WandButtonLogic.WandVisual.DISABLED ->
            Color.Gray.copy(alpha = 0.5f)
    }
    val tint = when (visual) {
        WandButtonLogic.WandVisual.READY -> MaterialTheme.colorScheme.onPrimaryContainer
        WandButtonLogic.WandVisual.DIMMED -> Color.White.copy(alpha = 0.7f)
        WandButtonLogic.WandVisual.DISABLED -> Color.White.copy(alpha = 0.35f)
        WandButtonLogic.WandVisual.OPTIMIZING -> MaterialTheme.colorScheme.onPrimaryContainer
    }
    Box(
        modifier = modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(container)
            .clickable(
                enabled = tappable,
                onClickLabel = OptimizerStrings.WAND_LABEL,
                role = Role.Button,
                onClick = onTap,
            )
            .semantics {
                contentDescription = OptimizerStrings.WAND_LABEL
                // Without this a screen-reader user hears "Optimize Prompt" with
                // no sign that a 20 s optimize is running, or that the button is
                // inert because there is no session.
                WandButtonLogic.stateDescription(visual)?.let { stateDescription = it }
            },
        contentAlignment = Alignment.Center,
    ) {
        if (visual == WandButtonLogic.WandVisual.OPTIMIZING) {
            CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                strokeWidth = 2.dp,
                color = tint,
            )
        } else {
            Icon(
                imageVector = Icons.Filled.AutoAwesome,
                contentDescription = null, // the Box carries WAND_LABEL
                tint = tint,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

/**
 * The wand plus whatever sits above it: the 4 s notice toast (top, tap =
 * dismiss) and the "Optimized · Undo" chip (10 s, tap = one-shot undo). Anchor
 * it bottom-end over the terminal.
 *
 * A notice and an undo can be on screen together, exactly as in Swift
 * (`WandButton.swift:41-65`): the two timers are independent, so suppressing the
 * chip while a toast is up could let the undo window expire unseen and discard
 * the user's original draft. The decision itself is
 * [WandButtonLogic.overlayContent], so it is JVM-testable.
 */
@Composable
fun OptimizerOverlay(
    visual: WandButtonLogic.WandVisual,
    undoVisible: Boolean,
    notice: String?,
    onWandTap: () -> Unit,
    onUndoTap: () -> Unit,
    onNoticeDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val content = WandButtonLogic.overlayContent(notice = notice, undoVisible = undoVisible)
    Column(modifier = modifier, horizontalAlignment = Alignment.End) {
        content.notice?.let { text ->
            OptimizerNotice(text, onDismiss = onNoticeDismiss)
            Spacer(Modifier.height(8.dp))
        }
        if (content.showUndo) {
            // Same predicate as the wand: while a second optimize is in flight an
            // undo tap would be dropped by the controller with no feedback, so the
            // chip dims instead of silently no-opping (Swift disables it too).
            UndoChip(onTap = onUndoTap, enabled = WandButtonLogic.isTappable(visual))
            Spacer(Modifier.height(8.dp))
        }
        WandButton(visual = visual, onTap = onWandTap)
    }
}

@Composable
private fun UndoChip(onTap: () -> Unit, enabled: Boolean) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.inverseSurface)
            .clickable(enabled = enabled, role = Role.Button, onClick = onTap)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text(
            text = OptimizerStrings.OPTIMIZED + " · " + OptimizerStrings.UNDO,
            color = MaterialTheme.colorScheme.inverseOnSurface.copy(alpha = if (enabled) 1f else 0.4f),
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun OptimizerNotice(text: String, onDismiss: () -> Unit) {
    Box(
        modifier = Modifier
            .widthIn(max = 320.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.inverseSurface)
            // Tap-to-dismiss, like Swift's notice chip: without it a 4 s toast
            // cannot be cleared early and can outlive what it sits next to.
            .clickable(role = Role.Button, onClick = onDismiss)
            .padding(horizontal = 14.dp, vertical = 8.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
    ) {
        Text(
            text = text,
            color = MaterialTheme.colorScheme.inverseOnSurface,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}
