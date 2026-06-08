package relay.terminal

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * A horizontal scrollable bar of special keys for terminal interaction.
 *
 * Ported from `ClaudeRelayApp/Views/Components/KeyboardAccessory.swift`. Each
 * button emits raw bytes through [onKey]; the host wires that to the session's
 * input send path.
 *
 * The key set mirrors the iOS bar exactly:
 *  - return, ESC, tab, and a delete button wired to [SpecialKeys.clearToPrompt]
 *    (NOT a bare backspace — it clears the whole prompt incl. continuation lines)
 *  - the digit quick-keys 1 / 2 / 3
 *  - the four arrow keys (CSI sequences)
 *  - Ctrl-C / Ctrl-R / Ctrl-A / Ctrl-E / Ctrl-D / Ctrl-Z / Ctrl-L
 *  - the symbol quick-keys | / ~ - _
 *
 * iOS uses SF Symbols for the return/arrow/delete glyphs; this port substitutes
 * short ASCII labels since those icon assets are not available on Android.
 */
@Composable
fun KeyboardAccessory(
    onKey: (ByteArray) -> Unit,
    modifier: Modifier = Modifier
) {
    LazyRow(
        modifier = modifier
            .fillMaxWidth()
            .height(40.dp)
            .background(Color.Black),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
        contentPadding = PaddingValues(horizontal = 8.dp)
    ) {
        // Whitespace / control keys.
        item { KeyButton(label = "↵", onClick = { onKey(SpecialKeys.RETURN) }) }       // return ↵
        item { KeyButton(label = "ESC", onClick = { onKey(SpecialKeys.ESC) }) }
        item { KeyButton(label = "⇥", onClick = { onKey(SpecialKeys.TAB) }) }           // tab ⇥
        item { KeyButton(label = "⌫", onClick = { onKey(SpecialKeys.clearToPrompt()) }) } // delete ⌫ → clearToPrompt

        // Digit quick-keys (iOS bar exposes 1 / 2 / 3).
        item { CharButton('1', onKey) }
        item { CharButton('2', onKey) }
        item { CharButton('3', onKey) }

        // Arrow keys (CSI sequences).
        item { KeyButton(label = "↑", onClick = { onKey(SpecialKeys.UP) }) }
        item { KeyButton(label = "↓", onClick = { onKey(SpecialKeys.DOWN) }) }
        item { KeyButton(label = "←", onClick = { onKey(SpecialKeys.LEFT) }) }
        item { KeyButton(label = "→", onClick = { onKey(SpecialKeys.RIGHT) }) }

        item { KeyDivider() }

        // Ctrl combos — same set/order as the iOS bar.
        item { CtrlComboButton('C', SpecialKeys.CTRL_C, onKey) }
        item { CtrlComboButton('R', SpecialKeys.CTRL_R, onKey) }
        item { CtrlComboButton('A', SpecialKeys.CTRL_A, onKey) }
        item { CtrlComboButton('E', SpecialKeys.CTRL_E, onKey) }
        item { CtrlComboButton('D', SpecialKeys.CTRL_D, onKey) }
        item { CtrlComboButton('Z', SpecialKeys.CTRL_Z, onKey) }
        item { CtrlComboButton('L', SpecialKeys.CTRL_L, onKey) }

        item { KeyDivider() }

        // Symbol quick-keys.
        item { CharButton('|', onKey) }
        item { CharButton('/', onKey) }
        item { CharButton('~', onKey) }
        item { CharButton('-', onKey) }
        item { CharButton('_', onKey) }
    }
}

// MARK: - Button builders

private val ButtonShape = RoundedCornerShape(5.dp)
private val ButtonBackground = Color(0xFF2C2C2E)
private val ButtonForeground = Color.White

/** A labelled key button — used for the control/arrow/delete keys. */
@Composable
private fun KeyButton(label: String, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = ButtonShape,
        color = ButtonBackground,
        contentColor = ButtonForeground
    ) {
        Box(
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 5.dp),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = label,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = ButtonForeground
            )
        }
    }
}

/** A monospaced single-character key (digits + the | / ~ - _ symbols). */
@Composable
private fun CharButton(char: Char, onKey: (ByteArray) -> Unit) {
    Surface(
        onClick = { onKey(SpecialKeys.literal(char)) },
        shape = ButtonShape,
        color = ButtonBackground,
        contentColor = ButtonForeground
    ) {
        Box(
            modifier = Modifier
                .width(28.dp)
                .padding(vertical = 5.dp),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = char.toString(),
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                fontFamily = FontFamily.Monospace,
                color = ButtonForeground
            )
        }
    }
}

/** A Ctrl-<letter> combo key. Renders a `^` prefix then the monospaced letter. */
@Composable
private fun CtrlComboButton(letter: Char, bytes: ByteArray, onKey: (ByteArray) -> Unit) {
    Surface(
        onClick = { onKey(bytes) },
        shape = ButtonShape,
        color = ButtonBackground,
        contentColor = ButtonForeground
    ) {
        Box(
            modifier = Modifier
                .padding(horizontal = 7.dp, vertical = 5.dp),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "^$letter",
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                fontFamily = FontFamily.Monospace,
                color = ButtonForeground
            )
        }
    }
}

/** A thin vertical separator matching the iOS bar's `Divider().frame(height: 24)`. */
@Composable
private fun KeyDivider() {
    Box(
        modifier = Modifier
            .width(1.dp)
            .height(24.dp)
            .background(Color(0xFF48484A))
    )
}

@Preview
@Composable
private fun KeyboardAccessoryPreview() {
    KeyboardAccessory(onKey = {})
}
