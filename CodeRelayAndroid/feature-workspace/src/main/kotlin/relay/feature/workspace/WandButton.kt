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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
            .clickable(enabled = tappable, onClick = onTap)
            .semantics { contentDescription = OptimizerStrings.WAND_LABEL },
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
 * The wand plus whatever sits above it: the "Optimized · Undo" chip (10 s, tap =
 * one-shot undo) or the 4 s notice toast. Anchor it bottom-end over the terminal.
 *
 * When both a notice and an undo are present the notice wins — it is the newer
 * information and expires first, after which the chip shows again.
 */
@Composable
fun OptimizerOverlay(
    visual: WandButtonLogic.WandVisual,
    undoVisible: Boolean,
    notice: String?,
    onWandTap: () -> Unit,
    onUndoTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier, horizontalAlignment = Alignment.End) {
        when {
            notice != null -> {
                OptimizerNotice(notice)
                Spacer(Modifier.height(8.dp))
            }
            undoVisible -> {
                UndoChip(onUndoTap)
                Spacer(Modifier.height(8.dp))
            }
        }
        WandButton(visual = visual, onTap = onWandTap)
    }
}

@Composable
private fun UndoChip(onTap: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.inverseSurface)
            .clickable(onClick = onTap)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text(
            text = OptimizerStrings.OPTIMIZED + " · " + OptimizerStrings.UNDO,
            color = MaterialTheme.colorScheme.inverseOnSurface,
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun OptimizerNotice(text: String) {
    Box(
        modifier = Modifier
            .widthIn(max = 320.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.inverseSurface)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text(
            text = text,
            color = MaterialTheme.colorScheme.inverseOnSurface,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}
