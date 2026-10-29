package relay.feature.workspace.ui

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import relay.session.SessionLoadingPresentation
import kotlin.coroutines.cancellation.CancellationException
import relay.session.SessionLoadingSheetModel

/** Geometry and type for the loading sheet, shared by Android and Linux and matched to the Apple apps. */
object SessionLoadingSheetStyle {
    /** The byte counter is the largest text: it is the one line that proves the load is moving. */
    const val BYTES_SP = 24
    const val STATUS_SP = 14
    /** Quick to black (the user just acted), slower back so the fresh screen resolves. */
    const val COVER_OUT_MS = 160
    const val COVER_IN_MS = 220
    /** One width on tablets and the desktop (the Apple apps' 340 pt); a phone spans the screen. */
    const val MAX_WIDTH_DP = 340

    /** Windows at least this wide are tablet-class (Material's medium width) and get the fixed card. */
    private const val TABLET_WIDTH_DP = 600f

    /** The sheet's width cap for a window [screenWidthDp] wide, or null to span it (phones, like the iPhone). */
    fun maxWidthDpFor(screenWidthDp: Float): Int? = if (screenWidthDp >= TABLET_WIDTH_DP) MAX_WIDTH_DP else null
}

/** Black over the terminal while the loading sheet is up; both lift together. */
fun Modifier.terminalLoadingCover(covered: Boolean): Modifier = composed {
    val alpha by animateFloatAsState(
        targetValue = if (covered) 1f else 0f,
        animationSpec = tween(if (covered) SessionLoadingSheetStyle.COVER_OUT_MS else SessionLoadingSheetStyle.COVER_IN_MS),
        label = "terminalLoadingCover",
    )
    drawWithContent {
        drawContent()
        if (alpha > 0f) drawRect(Color.Black.copy(alpha = alpha))
    }
}

/**
 * The one bottom sheet for a switch, the session-name refresh and a reconnect.
 * Never dismissible by the user — the load ends it (or the model's stall
 * ceiling does). Every row is laid out in every state and hidden when empty,
 * so the sheet keeps one size from the first phase to "Ready" and the Cancel
 * row exists even when only a reconnect shows it; nothing can be clipped
 * because the height is the content's own.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionLoadingSheetHost(model: SessionLoadingSheetModel, onCancel: () -> Unit) {
    val presented by model.isPresented.collectAsState()
    val shown by model.shown.collectAsState()
    var visible by remember { mutableStateOf(false) }
    var allowHide by remember { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = { it != SheetValue.Hidden || allowHide },
    )
    LaunchedEffect(presented) {
        if (presented) {
            allowHide = false
            // A load that starts while the previous one's sheet is sliding away
            // cancels that hide part-way; the sheet stays composed, so its
            // one-time show-on-enter never runs again — show it explicitly.
            if (visible && sheetState.targetValue == SheetValue.Hidden) {
                try { sheetState.show() } catch (e: CancellationException) { throw e } catch (_: Throwable) {}
            }
            visible = true
        } else if (visible) {
            allowHide = true
            // Cancellation must propagate: a swallowed one ran `visible = false`
            // after the NEXT load had started, hiding its sheet mid-load.
            try { sheetState.hide() } catch (e: CancellationException) { throw e } catch (_: Throwable) {}
            visible = false
        }
    }
    val p = shown
    if (!visible || p == null) return
    val windowWidthDp = with(LocalDensity.current) { LocalWindowInfo.current.containerSize.width.toDp().value }
    ModalBottomSheet(
        onDismissRequest = {},
        sheetState = sheetState,
        sheetMaxWidth = SessionLoadingSheetStyle.maxWidthDpFor(windowWidthDp)?.dp ?: Dp.Unspecified,
        dragHandle = null,
    ) {
        SessionLoadingSheetContent(p, onCancel)
    }
}

@Composable
internal fun SessionLoadingSheetContent(p: SessionLoadingPresentation, onCancel: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(24.dp)
            .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.height(36.dp), contentAlignment = Alignment.Center) {
            if (p.isReady) {
                Icon(
                    Icons.Filled.CheckCircle,
                    contentDescription = null,
                    tint = Color(0xFF34C759),
                    modifier = Modifier.size(32.dp),
                )
            } else {
                CircularProgressIndicator(modifier = Modifier.size(32.dp))
            }
        }
        Text(p.title, style = MaterialTheme.typography.titleMedium, maxLines = 1)
        val bytes = p.detail ?: "0 KB"
        Text(
            bytes,
            fontSize = SessionLoadingSheetStyle.BYTES_SP.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
            maxLines = 1,
            modifier = Modifier
                .alpha(if (p.detail == null) 0f else 1f)
                .semantics { contentDescription = "$bytes loaded" },
        )
        Text(
            p.status,
            fontSize = SessionLoadingSheetStyle.STATUS_SP.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
        )
        Text(
            p.subtitle ?: " ",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.outline,
            maxLines = 1,
        )
        OutlinedButton(
            onClick = onCancel,
            enabled = p.allowsCancel,
            modifier = Modifier.alpha(if (p.allowsCancel) 1f else 0f),
        ) { Text("Cancel") }
    }
}
