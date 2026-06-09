package relay.feature.workspace

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicNone
import androidx.compose.material.icons.filled.Textsms
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.flow.StateFlow
import relay.speech.ContinuousListeningState
import relay.speech.ListeningColor
import relay.speech.SpeechEngineState

/**
 * Dual-mode microphone button, ported from `MicButton.swift`.
 *
 * **Two modes, gated on [continuousEnabled]** (the `AppSettings.continuousListeningEnabled`
 * value the host collects):
 *  - **Push-to-talk** (default): tap to start recording, tap again to stop +
 *    transcribe + deliver. Observes [OnDeviceSpeechEngine.state].
 *  - **Continuous**: tap to enable/disable always-on listening; a **long-press**
 *    runs a one-shot PTT capture WITHOUT disabling continuous mode (Swift
 *    `beginTemporaryPTT`). Observes the [ContinuousListeningEngine.state].
 *
 * **State-driven icon + colour** mirrors `MicButton.swift`'s `effectiveIcon` /
 * `effectiveBackgroundColor`, using the [ContinuousListeningState.color] buckets
 * (blue = waiting for wake word, red = armed/recording, yellow = processing) in
 * continuous mode and the PTT engine state in default mode.
 *
 * **Download-progress ring**: when [downloadProgress] is non-null (the
 * [SpeechModelStore] is fetching the Whisper + Qwen models) the button shows a
 * determinate ring instead of the icon, and taps are disabled.
 *
 * ## Decoupling from concrete engine types (compile-only seam)
 * The Swift button holds concrete `@ObservedObject` engines. To keep
 * `:feature-workspace` from depending on the device-deferred engine *plumbing*
 * (audio capture / JNI), this Composable takes the engine **state flows** + the
 * tap/long-press **action callbacks** as parameters; `:app` constructs the real
 * engines and supplies the flows + actions. The state→icon/colour mapping (the
 * load-bearing, testable part) lives here; runtime engine behaviour is
 * device-deferred.
 *
 * @param continuousEnabled AppSettings.continuousListeningEnabled
 * @param pttState push-to-talk engine state flow (default mode)
 * @param continuousState continuous-listening engine state flow
 * @param downloadProgress model-download progress flow (null = not downloading)
 * @param modelsReady whether the on-device models are present (gates PTT start)
 * @param hapticsEnabled AppSettings.hapticFeedbackEnabled — gates the tap haptics
 *   (`MicButton.swift`'s `UIImpactFeedbackGenerator(.medium)` on every tap that
 *   starts/stops a capture or toggles continuous mode). Success/warning
 *   notification haptics fire from the host after transcription (see SpeechSession).
 * @param onPttTap default-mode tap: toggle record/stop (host runs the engine)
 * @param onContinuousTap continuous-mode tap: enable/disable listening
 * @param onLongPressOneShot continuous-mode long-press: one-shot PTT capture
 * @param onRequestDownload user accepted the download prompt (host kicks it off)
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun MicButton(
    continuousEnabled: Boolean,
    pttState: StateFlow<SpeechEngineState>,
    continuousState: StateFlow<ContinuousListeningState>,
    downloadProgress: StateFlow<Double?>,
    modelsReady: Boolean,
    hapticsEnabled: Boolean,
    onPttTap: () -> Unit,
    onContinuousTap: () -> Unit,
    onLongPressOneShot: () -> Unit,
    onRequestDownload: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = rememberHaptics(hapticsEnabled)
    val ptt by pttState.collectAsStateWithLifecycle()
    val continuous by continuousState.collectAsStateWithLifecycle()
    val progress by downloadProgress.collectAsStateWithLifecycle()

    var showDownloadAlert by remember { mutableStateOf(false) }

    val icon = effectiveIcon(continuousEnabled, ptt, continuous)
    val bg = effectiveBackgroundColor(continuousEnabled, ptt, continuous)
    val disabled = isButtonDisabled(ptt, progress)

    Box(
        modifier = modifier
            .size(44.dp)
            .background(bg, CircleShape)
            .combinedClickable(
                enabled = !disabled,
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = {
                    if (continuousEnabled) {
                        // Swift handleContinuousTap fires .medium impact on every tap.
                        haptics.mediumTap()
                        onContinuousTap()
                    } else {
                        // PTT: gate the very first start behind the download prompt.
                        if (ptt is SpeechEngineState.Idle && !modelsReady) {
                            // Swift fires NO haptic on the download-prompt branch.
                            showDownloadAlert = true
                        } else {
                            // Swift handlePTTTap fires .medium impact ONLY on the
                            // start (.idle) and stop (.recording) branches — NOT on
                            // the .error (cancel) branch (MicButton.swift:124-160).
                            if (ptt is SpeechEngineState.Idle || ptt is SpeechEngineState.Recording) {
                                haptics.mediumTap()
                            }
                            onPttTap()
                        }
                    }
                },
                onLongClick = {
                    // Long-press one-shot PTT only meaningful in continuous mode.
                    // Swift performOneShotPTT fires .medium impact at start
                    // (MicButton.swift:108-109).
                    if (continuousEnabled) {
                        haptics.mediumTap()
                        onLongPressOneShot()
                    }
                },
            ),
        contentAlignment = Alignment.Center,
    ) {
        val p = progress
        if (p != null) {
            CircularProgressIndicator(
                progress = { p.toFloat() },
                modifier = Modifier.size(24.dp),
                color = Color.White,
                trackColor = Color.White.copy(alpha = 0.3f),
            )
        } else {
            Icon(icon, contentDescription = "Voice input", tint = Color.White)
        }
    }

    if (showDownloadAlert) {
        AlertDialog(
            onDismissRequest = { showDownloadAlert = false },
            title = { Text("Download Speech Models?") },
            text = {
                Text(
                    "On-device voice recognition requires a one-time download (~0.5 GB). " +
                        "This enables offline, private speech-to-text.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    showDownloadAlert = false
                    onRequestDownload()
                }) { Text("Download") }
            },
            dismissButton = {
                TextButton(onClick = { showDownloadAlert = false }) { Text("Cancel") }
            },
        )
    }
}

// MARK: - State → icon / colour (ported from MicButton.swift, pure & testable)

/**
 * Icon for the current state. Mirrors `MicButton.swift`'s `effectiveIcon`,
 * mapping SF Symbols to Material icons: mic→Mic/MicNone, waveform→GraphicEq,
 * sparkles→AutoAwesome, text.bubble→Textsms.
 */
internal fun effectiveIcon(
    continuousEnabled: Boolean,
    ptt: SpeechEngineState,
    continuous: ContinuousListeningState,
): ImageVector =
    if (continuousEnabled) {
        when (continuous) {
            ContinuousListeningState.Idle -> Icons.Filled.MicNone
            ContinuousListeningState.Listening,
            ContinuousListeningState.DetectingWakeWord -> Icons.Filled.GraphicEq
            ContinuousListeningState.Armed,
            ContinuousListeningState.Recording,
            ContinuousListeningState.DetectingTurnEnd -> Icons.Filled.Mic
            ContinuousListeningState.Transcribing -> Icons.Filled.GraphicEq
            ContinuousListeningState.Cleaning -> Icons.Filled.AutoAwesome
            ContinuousListeningState.Outputting -> Icons.Filled.Textsms
            is ContinuousListeningState.Error -> Icons.Filled.MicNone
        }
    } else {
        when (ptt) {
            SpeechEngineState.Idle, SpeechEngineState.LoadingModel -> Icons.Filled.MicNone
            SpeechEngineState.Recording -> Icons.Filled.Mic
            SpeechEngineState.Transcribing -> Icons.Filled.GraphicEq
            SpeechEngineState.Cleaning -> Icons.Filled.AutoAwesome
            is SpeechEngineState.Error -> Icons.Filled.MicNone
        }
    }

/**
 * Background colour for the current state. Mirrors `MicButton.swift`'s
 * `effectiveBackgroundColor`: continuous mode uses the [ListeningColor] buckets
 * (blue / red / yellow) plus grey-idle; PTT mode is green-idle / red-recording /
 * yellow-processing. Error is always red.
 */
internal fun effectiveBackgroundColor(
    continuousEnabled: Boolean,
    ptt: SpeechEngineState,
    continuous: ContinuousListeningState,
): Color =
    if (continuousEnabled) {
        when (continuous) {
            ContinuousListeningState.Idle -> Color.Gray.copy(alpha = 0.5f)
            is ContinuousListeningState.Error -> Color.Red.copy(alpha = 0.8f)
            else -> when (continuous.color) {
                ListeningColor.BLUE -> Color.Blue.copy(alpha = 0.8f)
                ListeningColor.RED -> Color.Red.copy(alpha = 0.8f)
                ListeningColor.YELLOW -> Color.Yellow.copy(alpha = 0.8f)
                null -> Color.Gray.copy(alpha = 0.5f)
            }
        }
    } else {
        when (ptt) {
            SpeechEngineState.Idle, SpeechEngineState.LoadingModel -> Color.Green.copy(alpha = 0.8f)
            SpeechEngineState.Recording -> Color.Red.copy(alpha = 0.8f)
            SpeechEngineState.Transcribing, SpeechEngineState.Cleaning -> Color.Yellow.copy(alpha = 0.8f)
            is SpeechEngineState.Error -> Color.Red.copy(alpha = 0.8f)
        }
    }

/**
 * Whether the button is disabled. Mirrors `MicButton.swift`'s `isButtonDisabled`:
 * disabled while loading/transcribing/cleaning (PTT) or whenever a download
 * progress ring is showing.
 */
internal fun isButtonDisabled(ptt: SpeechEngineState, downloadProgress: Double?): Boolean =
    when (ptt) {
        SpeechEngineState.LoadingModel,
        SpeechEngineState.Transcribing,
        SpeechEngineState.Cleaning -> true
        else -> downloadProgress != null
    }

/**
 * Whether continuous listening should be re-enabled after a one-shot PTT capture.
 * Mirrors `MicButton.swift:97` (`beginTemporaryPTT`):
 * `if settings.continuousListeningEnabled && !continuousPausedByUser`. A user who
 * tap-paused continuous mode ([pausedByUser] == true) must NOT have it silently
 * resumed by a long-press one-shot.
 */
fun shouldResumeAfterOneShot(continuousEnabled: Boolean, pausedByUser: Boolean): Boolean =
    continuousEnabled && !pausedByUser
