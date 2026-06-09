package relay.terminal

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.KeyboardReturn
import androidx.compose.material.icons.automirrored.filled.KeyboardTab
import androidx.compose.material.icons.filled.Backspace
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * A horizontal scrollable bar of special keys for terminal interaction.
 *
 * Ported VALUE-for-VALUE from `ClaudeRelayApp/Views/Components/KeyboardAccessory.swift`.
 * Each button emits raw bytes through [onKey]; the host wires that to the session's
 * input send path.
 *
 * The key set, order, and styling mirror the iOS bar exactly:
 *  - return, ESC, tab, and a delete button wired to [SpecialKeys.clearToPrompt]
 *    (NOT a bare backspace — it clears the whole prompt incl. continuation lines)
 *  - the digit quick-keys 1 / 2 / 3
 *  - the four arrow keys (CSI sequences)
 *  - Ctrl-C / Ctrl-R / Ctrl-A / Ctrl-E / Ctrl-D / Ctrl-Z / Ctrl-L
 *  - the symbol quick-keys | / ~ - _
 *
 * iOS uses SF Symbols for the return/tab/delete/arrow glyphs. This port uses the
 * Material equivalents (KeyboardReturn / KeyboardTab / Backspace / KeyboardArrow*)
 * — REAL vector icons, not the Unicode glyphs (↵ ⇥ ⌫ →) the earlier version used,
 * which failed to render on some device fonts (showing blank keys).
 *
 * Layout matches iOS: a single horizontally-scrolling Row with `spacedBy(6dp)`,
 * 8dp horizontal content padding, 40dp tall, black background; per-key 5dp corners,
 * 18dp icons, monospace char keys with a 28dp min width.
 */
@Composable
fun KeyboardAccessory(
    onKey: (ByteArray) -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(40.dp)
            .background(Color.Black)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Whitespace / control keys (icons, like the iOS keyButton).
        IconKey(Icons.AutoMirrored.Filled.KeyboardReturn, "return") { onKey(SpecialKeys.RETURN) }
        TextKey("ESC") { onKey(SpecialKeys.ESC) }
        IconKey(Icons.AutoMirrored.Filled.KeyboardTab, "tab") { onKey(SpecialKeys.TAB) }
        IconKey(Icons.Filled.Backspace, "delete") { onKey(SpecialKeys.clearToPrompt()) }

        // Digit quick-keys (iOS bar exposes 1 / 2 / 3).
        CharKey('1', onKey)
        CharKey('2', onKey)
        CharKey('3', onKey)

        // Arrow keys (CSI sequences).
        IconKey(Icons.Filled.KeyboardArrowUp, "up") { onKey(SpecialKeys.UP) }
        IconKey(Icons.Filled.KeyboardArrowDown, "down") { onKey(SpecialKeys.DOWN) }
        IconKey(Icons.AutoMirrored.Filled.KeyboardArrowLeft, "left") { onKey(SpecialKeys.LEFT) }
        IconKey(Icons.AutoMirrored.Filled.KeyboardArrowRight, "right") { onKey(SpecialKeys.RIGHT) }

        KeyDivider()

        // Ctrl combos — same set/order as the iOS bar.
        CtrlKey('C', SpecialKeys.CTRL_C, onKey)
        CtrlKey('R', SpecialKeys.CTRL_R, onKey)
        CtrlKey('A', SpecialKeys.CTRL_A, onKey)
        CtrlKey('E', SpecialKeys.CTRL_E, onKey)
        CtrlKey('D', SpecialKeys.CTRL_D, onKey)
        CtrlKey('Z', SpecialKeys.CTRL_Z, onKey)
        CtrlKey('L', SpecialKeys.CTRL_L, onKey)

        KeyDivider()

        // Symbol quick-keys.
        CharKey('|', onKey)
        CharKey('/', onKey)
        CharKey('~', onKey)
        CharKey('-', onKey)
        CharKey('_', onKey)
    }
}

// MARK: - Button builders (match the iOS KeyboardAccessory builders)

private val KeyShape = RoundedCornerShape(5.dp)
// iOS tertiary/secondary system backgrounds in dark mode ≈ these dark greys.
private val IconKeyBg = Color(0xFF2C2C2E)   // .tertiarySystemBackground (dark)
private val TextKeyBg = Color(0xFF1C1C1E)   // .secondarySystemBackground (dark)
private val KeyFg = Color.White

/** An icon key (return / tab / delete / arrows) — iOS `keyButton(icon:)`. */
@Composable
private fun IconKey(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(KeyShape)
            .background(IconKeyBg)
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 5.dp),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = KeyFg,
            modifier = Modifier.height(18.dp),
        )
    }
}

/** A text key (ESC) — iOS `textKeyButton`. */
@Composable
private fun TextKey(label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(KeyShape)
            .background(TextKeyBg)
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 5.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text = label, color = KeyFg, fontSize = 11.sp, fontWeight = FontWeight.Medium)
    }
}

/** A monospaced single-character key (digits + the | / ~ - _ symbols) — iOS `charButton`. */
@Composable
private fun CharKey(char: Char, onKey: (ByteArray) -> Unit) {
    Box(
        modifier = Modifier
            .clip(KeyShape)
            .background(TextKeyBg)
            .clickable { onKey(SpecialKeys.literal(char)) }
            .widthIn(min = 28.dp)
            .padding(vertical = 5.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = char.toString(),
            color = KeyFg,
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            fontFamily = FontFamily.Monospace,
        )
    }
}

/** A Ctrl-<letter> combo key — iOS `ctrlComboButton` (a "^" prefix + monospaced letter). */
@Composable
private fun CtrlKey(letter: Char, bytes: ByteArray, onKey: (ByteArray) -> Unit) {
    Box(
        modifier = Modifier
            .clip(KeyShape)
            .background(IconKeyBg)
            .clickable { onKey(bytes) }
            .padding(horizontal = 7.dp, vertical = 5.dp),
        contentAlignment = Alignment.Center,
    ) {
        // iOS uses the SF Symbol "control" (the ⌃ caret) + the letter; "^<letter>"
        // is the rendering-safe ASCII equivalent.
        Text(
            text = "^$letter",
            color = KeyFg,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            fontFamily = FontFamily.Monospace,
        )
    }
}

/** A thin vertical separator matching the iOS bar's `Divider().frame(height: 24)`. */
@Composable
private fun KeyDivider() {
    Box(
        modifier = Modifier
            .padding(horizontal = 2.dp)
            .width(1.dp)
            .height(24.dp)
            .background(Color(0xFF48484A)),
    )
}

@Preview
@Composable
private fun KeyboardAccessoryPreview() {
    KeyboardAccessory(onKey = {})
}
