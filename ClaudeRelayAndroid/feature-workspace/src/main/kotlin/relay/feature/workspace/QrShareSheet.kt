package relay.feature.workspace

import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter
import java.util.UUID

/**
 * The QR share sheet, ported from `QRCodeSheet.swift`.
 *
 * A [ModalBottomSheet] showing the session name, a QR [Image] encoding
 * [DeepLinks.sessionUri], the selectable deep-link text below it, an explainer,
 * and a Close button. The QR bitmap is generated with ZXing
 * ([qrBitmap]) — the Android analog of iOS's `CIQRCodeGenerator`.
 *
 * COMPILE-VERIFIED ONLY: [android.graphics.Bitmap] needs an Android runtime, so
 * the actual QR render is DEVICE-DEFERRED. The encode logic is straight ZXing.
 *
 * @param sessionId the session to share
 * @param sessionName display name (falls back to the short id, like iOS)
 * @param onDismiss close the sheet
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QrShareSheet(
    sessionId: UUID,
    sessionName: String?,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val sheetState = rememberModalBottomSheetState()
    val deepLink = remember(sessionId) { DeepLinks.sessionUri(sessionId) }
    // Encode once per id; 560 px ≈ the iOS 280 pt @2x render.
    val bitmap = remember(deepLink) { runCatching { qrBitmap(deepLink, 560) }.getOrNull() }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp, vertical = 8.dp)
                .padding(bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                text = sessionName ?: sessionId.toString().take(8),
                style = MaterialTheme.typography.titleMedium,
            )

            if (bitmap != null) {
                Image(
                    painter = BitmapPainter(bitmap.asImageBitmap()),
                    contentDescription = "Session QR code",
                    modifier = Modifier
                        .size(280.dp)
                        .clip(RoundedCornerShape(12.dp)),
                )
            } else {
                Text(
                    text = "Could not generate QR code.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }

            // Selectable deep link (Swift `.textSelection(.enabled)`).
            SelectionContainer {
                Text(
                    text = deepLink,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
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

            TextButton(onClick = onDismiss) { Text("Close") }
        }
    }
}

/**
 * Encode [content] to a square QR [Bitmap] of [size] px using ZXing. Iterates the
 * `BitMatrix` and sets black/white pixels manually (ZXing's `core` is pure-JVM
 * and ships no Android rasterizer). The Android analog of iOS's
 * `CIQRCodeGenerator`.
 */
fun qrBitmap(content: String, size: Int): Bitmap {
    val matrix = MultiFormatWriter().encode(content, BarcodeFormat.QR_CODE, size, size)
    val width = matrix.width
    val height = matrix.height
    val pixels = IntArray(width * height)
    for (y in 0 until height) {
        val offset = y * width
        for (x in 0 until width) {
            pixels[offset + x] = if (matrix.get(x, y)) Color.BLACK else Color.WHITE
        }
    }
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
    return bitmap
}
