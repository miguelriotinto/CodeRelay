package relay.feature.workspace

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import java.util.UUID

/**
 * Desktop QR share sheet — the same surface as the Android `QrShareSheet` this
 * file replaces in the Linux build (see feature-workspace/build.gradle.kts).
 *
 * The Android sheet rasterises through `android.graphics.Bitmap`, which has no
 * desktop runtime. There is no need for a bitmap at all: a QR code is a grid of
 * squares, so the [QrModules] ZXing produces are drawn straight onto a Compose
 * [Canvas], which is resolution-independent and therefore crisp on the 2x panel
 * without a 560 px intermediate.
 *
 * Shown as a centred [Dialog] rather than a bottom sheet — a sheet sliding up
 * from the bottom of a 1400 px tall desktop window is a phone idiom. Adds a
 * "Copy link" button, because on a desktop the phone that will scan the code
 * may be in a pocket, while the clipboard is right here.
 *
 * @param sessionId the session to share
 * @param sessionName display name (falls back to the short id, like iOS)
 * @param onDismiss close the sheet
 */
@Composable
fun QrShareSheet(
    sessionId: UUID,
    sessionName: String?,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val deepLink = remember(sessionId) { DeepLinks.sessionUri(sessionId) }
    val modules = remember(deepLink) { runCatching { QrModules.encode(deepLink) }.getOrNull() }
    val clipboard = LocalClipboardManager.current

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            modifier = modifier,
            shape = RoundedCornerShape(16.dp),
            tonalElevation = 6.dp,
        ) {
            Column(
                modifier = Modifier.padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(
                    text = sessionName ?: sessionId.toString().take(8),
                    style = MaterialTheme.typography.titleMedium,
                )

                if (modules != null) {
                    QrImage(modules, modifier = Modifier.size(280.dp))
                } else {
                    Text(
                        text = "Could not generate QR code.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                }

                SelectionContainer {
                    Text(
                        text = deepLink,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                }

                Text(
                    text = "Scan this code from another device to attach to this session.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = { clipboard.setText(AnnotatedString(deepLink)) }) {
                        Text("Copy link")
                    }
                    TextButton(onClick = onDismiss) { Text("Close") }
                }
            }
        }
    }
}

/**
 * Draws [modules] black-on-white inside a white quiet zone. Always black on
 * white regardless of the app theme: an inverted code scans unreliably, and the
 * Omarchy palettes are mostly dark.
 */
@Composable
private fun QrImage(modules: QrModules, modifier: Modifier = Modifier) {
    val quietZone = 12.dp
    Canvas(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White)
            .padding(quietZone)
            .semantics { contentDescription = "Session QR code" },
    ) {
        val cell = size.minDimension / modules.size
        val side = Size(cell, cell)
        for (y in 0 until modules.size) {
            for (x in 0 until modules.size) {
                if (modules[x, y]) {
                    drawRect(Color.Black, topLeft = Offset(x * cell, y * cell), size = side)
                }
            }
        }
    }
}

/**
 * The module grid of a QR code — a square of dark/light cells, with no quiet
 * zone (the renderer adds its own).
 *
 * Pure JVM, so the encode is testable without a display: the test decodes the
 * grid back with ZXing's own decoder and checks the link survives the trip.
 */
class QrModules internal constructor(private val bits: Array<BooleanArray>) {
    /** Modules per side. */
    val size: Int get() = bits.size

    /** Whether the module at ([x], [y]) is dark. */
    operator fun get(x: Int, y: Int): Boolean = bits[y][x]

    companion object {
        /**
         * Encodes [content] at the smallest version that fits, with ZXing's
         * quiet zone disabled so [size] is exactly the symbol's module count.
         */
        fun encode(content: String): QrModules {
            val hints = mapOf(EncodeHintType.MARGIN to 0)
            val matrix = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, 0, 0, hints)
            val bits = Array(matrix.height) { y -> BooleanArray(matrix.width) { x -> matrix.get(x, y) } }
            return QrModules(bits)
        }
    }
}
