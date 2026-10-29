package relay.feature.workspace.hub

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

internal fun HeaderDot.color(): Color = when (this) {
    HeaderDot.GREEN -> Color(0xFF34C759)
    HeaderDot.ORANGE -> Color(0xFFFF9500)
    HeaderDot.RED -> Color(0xFFFF3B30)
    HeaderDot.GRAY -> Color(0xFF8E8E93)
}

/** One server section's header: dot, name, status, attention badge, Retry, New, collapse chevron. */
@Composable
fun ServerSectionHeader(
    model: ServerSectionHeaderModel,
    isCollapsed: Boolean,
    onToggle: () -> Unit,
    onRetry: () -> Unit,
    onNew: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(start = 12.dp, end = 4.dp, top = 10.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(8.dp).background(model.dot.color(), CircleShape))
        Column(
            modifier = Modifier
                .weight(1f)
                .semantics(mergeDescendants = true) { contentDescription = model.accessibilityLabel },
        ) {
            Text(model.title, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, maxLines = 1)
            model.subtitle?.let {
                Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            }
        }
        if (model.isDuplicate) {
            Icon(
                Icons.Filled.Warning,
                contentDescription = "Another bookmark points at this same relay",
                tint = HeaderDot.ORANGE.color(),
                modifier = Modifier.size(14.dp),
            )
        }
        if (model.badge > 0) {
            Text(
                "${model.badge}",
                color = Color.White,
                fontSize = 11.sp,
                modifier = Modifier
                    .background(Color(0xFFFF3B30).copy(alpha = 0.85f), RoundedCornerShape(50))
                    .padding(horizontal = 6.dp, vertical = 1.dp),
            )
        }
        if (model.offersRetry) {
            IconButton(onClick = onRetry, modifier = Modifier.size(32.dp)) {
                Icon(Icons.Filled.Refresh, contentDescription = "Retry ${model.title}", modifier = Modifier.size(18.dp))
            }
        }
        if (onNew != null) {
            IconButton(onClick = onNew, modifier = Modifier.size(32.dp)) {
                Icon(Icons.Filled.Add, contentDescription = "New session on ${model.title}", modifier = Modifier.size(18.dp))
            }
        }
        Icon(
            if (isCollapsed) Icons.AutoMirrored.Filled.KeyboardArrowRight else Icons.Filled.KeyboardArrowDown,
            contentDescription = if (isCollapsed) "Expand" else "Collapse",
            modifier = Modifier.size(18.dp),
        )
    }
}
