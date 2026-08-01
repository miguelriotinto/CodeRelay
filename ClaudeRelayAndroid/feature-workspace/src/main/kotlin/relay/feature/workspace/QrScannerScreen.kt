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
import androidx.compose.runtime.DisposableEffect
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
 * This session-attach entry point is a thin wrapper over the generalized
 * [QrScannerScreen] (`onDecoded`) overload: it accepts a scanned string only
 * when [DeepLinks.parseSessionId] resolves it, so pairing and any future scan
 * consumer can reuse the same camera pipeline without this one changing.
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
    QrScanner(
        onDecoded = { raw ->
            val sessionId = DeepLinks.parseSessionId(raw) ?: return@QrScanner false
            onSessionScanned(sessionId)
            true
        },
        onCancel = onCancel,
        modifier = modifier,
    )
}

/**
 * Generalized camera QR scanner. Runs decoded QR payloads through [onDecoded];
 * the caller inspects the raw string and returns `true` to ACCEPT it (which
 * latches the scanner + fires a haptic, so a single QR is consumed exactly once)
 * or `false` to keep scanning (an unrelated code does not dismiss the scanner).
 *
 * Session-attach ([QrScannerScreen]) passes a [DeepLinks.parseSessionId]
 * predicate; pairing passes a [relay.protocol.PairingURL.parse] predicate. One
 * camera pipeline, many consumers — the raw-string payload is the only coupling.
 * (Distinct name, not an overload: `(UUID)->Unit` and `(String)->Boolean` erase
 * to the same JVM signature.)
 *
 * @param onDecoded called on each decoded QR string; return true to accept+latch
 * @param onCancel leave the scanner without scanning
 */
@Composable
fun QrScanner(
    onDecoded: (String) -> Boolean,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current

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
                onDecoded = onDecoded,
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
    onDecoded: (String) -> Boolean,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    // Single-thread analysis executor; remembered so we can shut it down.
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    // Latch so we accept at most one QR (Swift `hasScanned`).
    val scanned = remember { java.util.concurrent.atomic.AtomicBoolean(false) }
    // The bound provider, captured once resolved so onDispose can unbind it.
    val cameraProviderRef = remember { java.util.concurrent.atomic.AtomicReference<ProcessCameraProvider?>(null) }
    // Set on dispose so the async provider callback, if it resolves AFTER we've
    // left composition, skips binding onto the already-terminated executor.
    val disposed = remember { java.util.concurrent.atomic.AtomicBoolean(false) }

    // On leaving composition: UNBIND the CameraX use cases FIRST (stops the camera
    // and halts frame dispatch to the analyzer), THEN shut the executor down.
    // Order matters — shutting the executor while use cases are still bound to the
    // Activity lifecycle lets CameraX submit frames to a terminated executor
    // (RejectedExecutionException) and can leave the camera active after nav-away.
    // Both are needed: unbind alone leaks the executor thread; shutdown alone
    // leaves the camera bound.
    DisposableEffect(Unit) {
        onDispose {
            disposed.set(true)
            cameraProviderRef.get()?.unbindAll()
            analysisExecutor.shutdown()
        }
    }

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val previewView = PreviewView(ctx)
            val providerFuture = ProcessCameraProvider.getInstance(ctx)
            providerFuture.addListener({
                val cameraProvider = providerFuture.get()
                cameraProviderRef.set(cameraProvider)
                // Provider resolved after we already left the scanner: don't bind
                // onto the terminated executor. Unbind defensively in case a
                // partial bind slipped in, and bail.
                if (disposed.get()) {
                    runCatching { cameraProvider.unbindAll() }
                    return@addListener
                }
                val preview = Preview.Builder().build().also {
                    it.setSurfaceProvider(previewView.surfaceProvider)
                }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                    .also { it.setAnalyzer(analysisExecutor, QrAnalyzer(ctx, scanned, onDecoded)) }

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
 * ML Kit [ImageAnalysis.Analyzer] that decodes QR codes and hands each raw
 * payload to [onDecoded]. When [onDecoded] returns true (the caller accepted the
 * code) it fires a haptic and latches, so exactly one QR is consumed; a false
 * return keeps scanning so an unrelated code does not dismiss the scanner.
 */
private class QrAnalyzer(
    private val context: Context,
    private val scanned: java.util.concurrent.atomic.AtomicBoolean,
    private val onDecoded: (String) -> Boolean,
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
                // Single-fire rests on ML Kit's success listeners defaulting to the
                // main thread + ImageAnalysis STRATEGY_KEEP_ONLY_LATEST closing each
                // proxy before the next frame is delivered: at most one decoded
                // result is handled at a time, so `scanned.get()` (set on accept)
                // gates every subsequent frame. The `for` loop's own guard stops a
                // multi-code frame from firing `onDecoded` twice.
                for (barcode in barcodes) {
                    if (scanned.get()) break
                    if (barcode.format != Barcode.FORMAT_QR_CODE) continue
                    val value = barcode.rawValue ?: continue
                    // `onDecoded` decides AND acts (navigate/attach); a `false`
                    // (unrecognized QR) leaves the latch clear so scanning continues.
                    if (onDecoded(value)) {
                        scanned.set(true)
                        vibrate(context)
                        break
                    }
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
