package relay.feature.workspace.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import relay.protocol.SessionInfo
import java.util.UUID

/**
 * Horizontal scrollable bar of numbered session tabs, ported from the
 * `sessionTabBar` / `SessionTab` pair in `ActiveTerminalView.swift:231-325`.
 *
 * Each tab is numbered by its 1-based position in [sessions] (the coordinator's
 * `sessions` order). The tab's background is agent-colored via [agentColor] of
 * `session.agent`; a session in [awaitingInput] flashes between its agent color
 * and a translucent white (the "needs attention" pulse). The active tab
 * ([activeSessionId]) gets a 2 dp white selection border and a bold number.
 *
 * The flash phase is a single shared [rememberInfiniteTransition] (0.5 s), so we
 * don't spin up a timer per tab — parity with the Swift parent's shared
 * `TimelineView` clock.
 *
 * @param onSelect tapping a tab routes here with the session id (the workspace
 *   wires it to `coordinator.switchToSession`).
 */
@Composable
fun SessionTabs(
    sessions: List<SessionInfo>,
    activeSessionId: UUID?,
    agentForSession: (UUID) -> String?,
    awaitingInput: Set<UUID>,
    onSelect: (UUID) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Shared flash phase for all "needs attention" tabs. 0..1 triangle wave; we
    // bucket it to a boolean "flashOn" at the 0.5 midpoint so the fill snaps
    // between agentColor and the dim white, like the Swift flashOn boolean.
    val transition = rememberInfiniteTransition(label = "tabFlash")
    val flashPhase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 500),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "tabFlashPhase",
    )
    val flashOn = flashPhase >= 0.5f

    LazyRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
        contentPadding = PaddingValues(horizontal = 2.dp),
    ) {
        itemsIndexed(sessions, key = { _, s -> s.id }) { index, session ->
            val isSelected = session.id == activeSessionId
            val agentId = agentForSession(session.id)
            val needsAttention = awaitingInput.contains(session.id)
            SessionTab(
                number = index + 1,
                isSelected = isSelected,
                agentId = agentId,
                needsAttention = needsAttention,
                flashOn = flashOn,
                onClick = { onSelect(session.id) },
            )
        }
    }
}

/** Translucent white fills the Swift tab uses for the non-agent / dim states. */
private val White15 = Color.White.copy(alpha = 0.15f)

/** Which edge a minimal-reveal scroll should align the selected tab to. */
internal enum class RevealEdge { LEADING, TRAILING }

/** A visible tab's geometry relative to the viewport's left edge (px). */
internal data class VisibleTab(val index: Int, val offset: Int, val size: Int)

/** Result of a minimal-reveal decision: scroll [index] to [edge], or no-op if null. */
internal data class RevealTarget(val index: Int, val edge: RevealEdge)

/**
 * Minimal-reveal decision for the session tab strip. Returns the target tab and
 * edge to scroll to, or null when the selected tab is already fully visible.
 *
 *  - selected fully inside [0, viewportWidth]      -> null (no scroll)
 *  - selected clipped/absent on the left           -> LEADING
 *  - selected clipped/absent on the right          -> TRAILING
 */
internal fun revealTarget(
    visible: List<VisibleTab>,
    viewportWidth: Int,
    selectedIndex: Int,
): RevealTarget? {
    if (visible.isEmpty()) return null
    val selected = visible.firstOrNull { it.index == selectedIndex }
    if (selected != null) {
        val fullyVisible = selected.offset >= 0 && selected.offset + selected.size <= viewportWidth
        if (fullyVisible) return null
        val edge = if (selected.offset < 0) RevealEdge.LEADING else RevealEdge.TRAILING
        return RevealTarget(selectedIndex, edge)
    }
    // Not currently laid out: decide by position relative to the visible window.
    val firstIndex = visible.first().index
    val edge = if (selectedIndex < firstIndex) RevealEdge.LEADING else RevealEdge.TRAILING
    return RevealTarget(selectedIndex, edge)
}

/**
 * Computes a tab's background fill, ported from
 * `ActiveTerminalView.swift:318-324`:
 *  - needsAttention → `flashOn ? agentColor : white15`
 *  - else agentId != null → agentColor
 *  - else → white15
 */
internal fun tabBackground(agentId: String?, needsAttention: Boolean, flashOn: Boolean): Color {
    val agent = agentColor(agentId)
    return when {
        needsAttention -> if (flashOn) agent else White15
        agentId != null -> agent
        else -> White15
    }
}

@Composable
private fun SessionTab(
    number: Int,
    isSelected: Boolean,
    agentId: String?,
    needsAttention: Boolean,
    flashOn: Boolean,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(6.dp)
    var box = Modifier
        .defaultMinSize(minWidth = 26.dp, minHeight = 22.dp)
        .clip(shape)
        .background(tabBackground(agentId, needsAttention, flashOn))
    if (isSelected) {
        box = box.border(width = 2.dp, color = Color.White, shape = shape)
    }
    box = box.clickable(onClick = onClick)
    Box(
        modifier = box.padding(horizontal = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = number.toString(),
            color = Color.White,
            fontSize = 12.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.SemiBold,
        )
    }
}

@Preview
@Composable
private fun SessionTabsPreview() {
    SessionTabs(
        sessions = emptyList(),
        activeSessionId = null,
        agentForSession = { null },
        awaitingInput = emptySet(),
        onSelect = {},
    )
}
