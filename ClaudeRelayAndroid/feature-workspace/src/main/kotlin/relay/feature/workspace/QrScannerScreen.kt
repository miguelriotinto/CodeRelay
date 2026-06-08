package relay.feature.workspace

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.UUID
import java.util.concurrent.Executors

private const val TAG = "QrScannerScreen"

/**
 * Camera QR scanner, ported from `QRScannerView.swift`.
 *
 * Wraps a CameraX [PreviewView] in an [AndroidView], runs [ImageAnalysis] frames
 * through ML Kit [BarcodeScanning], and on the first QR whose payload parses via
 * [DeepLinks.parseSessionId] fires a haptic and calls [onSessionScanned] (the
 * Swift `onCodeScanned` → `UUID` path). Non-session QR payloads are ignored so
 * an unrelated code does not dismiss the scanner.
 *
 * Runtime CAMERA permission is requested via
 * [rememberLauncherForActivityResult]; while denied a rationale + retry button is
 * shown (the Swift authorization-denied state).
 *
 * COMPILE-VERIFIED ONLY — actual camera capture + scan is DEVICE-DEFERRED (no
 * emulator camera in CI).
 *
 * @param onSessionScanned called once with the scanned session id
 * @param onCancel leave the scanner without scanning
 */
@Composable
fun QrScannerScreen(
    onSessionScanned: (UUID) -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    var hasPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted -> hasPermission = granted }

    // Request on first composition if not already granted.
    LaunchedEffect(Unit) {
        if (!hasPermission) permissionLauncher.launch(Manifest.permission.CAMERA)
    }

    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        if (hasPermission) {
            CameraPreview(
                onSessionScanned = onSessionScanned,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Column(
                modifier = Modifier.padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(
                    text = "Camera Access Needed",
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    text = "Allow camera access to scan a session QR code from another device.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                Button(onClick = { permissionLauncher.launch(Manifest.permission.CAMERA) }) {
                    Text("Allow Camera")
                }
                Button(onClick = onCancel) { Text("Cancel") }
            }
        }
    }
}

/**
 * The live preview + analysis pipeline. Binds a CameraX [Preview] and an
 * [ImageAnalysis] (backpressure: keep only the latest frame) to the lifecycle,
 * feeding frames to [QrAnalyzer].
 */
@Composable
private fun CameraPreview(
    onSessionScanned: (UUID) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    // Single-thread analysis executor; remembered so we can shut it down.
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    // Latch so we fire onSessionScanned at most once (Swift `hasScanned`).
    val scanned = remember { java.util.concurrent.atomic.AtomicBoolean(false) }

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val previewView = PreviewView(ctx)
            val providerFuture = ProcessCameraProvider.getInstance(ctx)
            providerFuture.addListener({
                val cameraProvider = providerFuture.get()
                val preview = Preview.Builder().build().also {
                    it.setSurfaceProvider(previewView.surfaceProvider)
                }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                    .also { it.setAnalyzer(analysisExecutor, QrAnalyzer(ctx, scanned, onSessionScanned)) }

                runCatching {
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        preview,
                        analysis,
                    )
                }.onFailure { Log.e(TAG, "Failed to bind camera use cases", it) }
            }, ContextCompat.getMainExecutor(ctx))
            previewView
        },
    )
}

/**
 * ML Kit [ImageAnalysis.Analyzer] that decodes QR codes and, on a payload that
 * parses to a session [UUID], fires a haptic + [onSessionScanned] exactly once.
 */
private class QrAnalyzer(
    private val context: Context,
    private val scanned: java.util.concurrent.atomic.AtomicBoolean,
    private val onSessionScanned: (UUID) -> Unit,
) : ImageAnalysis.Analyzer {
    private val scanner = BarcodeScanning.getClient()

    @OptIn(ExperimentalGetImage::class)
    override fun analyze(imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image
        if (mediaImage == null || scanned.get()) {
            imageProxy.close()
            return
        }
        val input = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
        scanner.process(input)
            .addOnSuccessListener { barcodes ->
                for (barcode in barcodes) {
                    if (barcode.format != Barcode.FORMAT_QR_CODE) continue
                    val value = barcode.rawValue ?: continue
                    val sessionId = DeepLinks.parseSessionId(value) ?: continue
                    if (scanned.compareAndSet(false, true)) {
                        vibrate(context)
                        onSessionScanned(sessionId)
                    }
                    break
                }
            }
            .addOnFailureListener { Log.w(TAG, "Barcode scan failed", it) }
            .addOnCompleteListener { imageProxy.close() }
    }
}

/** Short confirmation haptic (Swift `UIImpactFeedbackGenerator(.medium)`). */
@Suppress("DEPRECATION")
private fun vibrate(context: Context) {
    val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        val manager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
        manager?.defaultVibrator
    } else {
        context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }
    runCatching {
        vibrator?.vibrate(VibrationEffect.createOneShot(40, VibrationEffect.DEFAULT_AMPLITUDE))
    }
}
