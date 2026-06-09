package relay.app

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import relay.feature.settings.AppSettings
import relay.feature.workspace.MicButton
import relay.feature.workspace.WorkspaceViewModel
import relay.speech.ContinuousListeningEngine
import relay.speech.OnDeviceSpeechEngine
import relay.speech.SpeechEngineState
import relay.speech.SpeechModelStore
import relay.speech.audio.AudioCapturing
import relay.speech.cleanup.CloudPromptEnhancer
import relay.speech.cleanup.SpeechPostProcessor
import relay.speech.cleanup.TextCleaner

/**
 * Owns the speech engines + model store for a connection, and produces the
 * [MicButton] slot wired into the workspace status bar.
 *
 * This is the `:app`-layer integration glue Task 11 is about: it constructs the
 * device-deferred [OnDeviceSpeechEngine] (PTT) + [ContinuousListeningEngine]
 * (always-on) + [SpeechModelStore], and wires `onUtteranceReady → blank-skip →
 * WorkspaceViewModel.sendInput(text)` (the new String overload). It also drives
 * the [ContinuousListeningService] foreground service when continuous mode is on.
 *
 * ## Real vs device-deferred
 *  - **Real (compile-verified):** engine construction via the `makeDefault`
 *    factories, the model-store wiring, the utterance → terminal-input route, the
 *    foreground-service start/stop, and the download prompt → `downloadAllModels`.
 *  - **Device-deferred (no emulator / no mic / no JNI):** actual mic capture
 *    (the [AudioCapturing] here is a no-op stub; the real Oboe/AudioRecord capture
 *    is M3-F device work), the whisper.cpp / llama.cpp loading, the
 *    foreground-service + permission runtime, and the model downloads.
 *
 * @param scope a long-lived scope (the connection scope) owning the engines
 * @param settings the app settings for the speech options snapshot + continuous toggle
 */
class SpeechSession private constructor(
    private val appContext: Context,
    private val scope: CoroutineScope,
    private val settings: AppSettings,
    val modelStore: SpeechModelStore,
    val pttEngine: OnDeviceSpeechEngine,
    val continuousEngine: ContinuousListeningEngine,
) {

    /**
     * Best-effort, non-blocking model preload/check for the splash hook. Re-derives
     * the model-readiness flags from disk (a previous launch may have completed a
     * download). Does NOT kick off a download — the download is user-gated behind
     * the mic button's prompt, matching the iOS preload (which only loads
     * already-downloaded models). Safe to call off the main thread.
     */
    fun preloadCheck(): Boolean = modelStore.refreshFromDisk()

    /** Kicks off the (device-deferred) model download. Called from the mic prompt. */
    fun startDownload() {
        scope.launch { modelStore.downloadAllModels() }
    }

    /**
     * The [MicButton] bound to [vm]. Collects the continuous-enabled toggle, wires
     * the PTT / continuous engine state flows, and routes utterances to
     * `vm.sendInput(text)` via each engine's delivery path.
     */
    @Composable
    fun MicButtonSlot(vm: WorkspaceViewModel) {
        val continuousEnabled by settings.continuousListeningEnabled.collectAsStateWithLifecycle()
        val composeScope = rememberCoroutineScope()

        // Continuous engine delivers cleaned utterances here (also routed through
        // the foreground service Bridge when the service hosts the engine).
        remember(vm) {
            continuousEngine.onUtteranceReady = { text -> vm.sendInput(text) }
            ContinuousListeningService.Bridge.onUtterance = { text -> vm.sendInput(text) }
            true
        }

        MicButton(
            continuousEnabled = continuousEnabled,
            pttState = pttEngine.state,
            continuousState = continuousEngine.state,
            downloadProgress = modelStore.downloadProgress,
            modelsReady = modelStore.modelsReady,
            onPttTap = { handlePttTap(composeScope, vm) },
            onContinuousTap = { handleContinuousTap() },
            onLongPressOneShot = { handleOneShotPtt(composeScope, vm) },
            onRequestDownload = { startDownload() },
        )
    }

    // MARK: - PTT (default-mode tap)

    private fun handlePttTap(composeScope: CoroutineScope, vm: WorkspaceViewModel) {
        when (pttEngine.state.value) {
            SpeechEngineState.Idle -> {
                SpeechPermissions.request()
                pttEngine.startRecording()
            }
            SpeechEngineState.Recording -> composeScope.launch {
                val text = pttEngine.stopAndProcess(settings.currentSpeechOptions())
                if (text != null) vm.sendInput(text) // sendInput(String) blank-skips internally
            }
            is SpeechEngineState.Error -> pttEngine.cancel()
            else -> Unit
        }
    }

    // MARK: - Continuous (tap = enable/disable, long-press = one-shot PTT)

    private fun handleContinuousTap() {
        continuousEngine.updateOptions(settings.currentSpeechOptions())
        if (continuousEngine.state.value == relay.speech.ContinuousListeningState.Idle) {
            SpeechPermissions.request()
            ContinuousListeningService.Bridge.options = settings.currentSpeechOptions()
            ContinuousListeningService.start(appContext)
            continuousEngine.enable()
        } else {
            continuousEngine.disable()
            ContinuousListeningService.stop(appContext)
        }
    }

    /** One-shot PTT during continuous mode (Swift `beginTemporaryPTT`). */
    private fun handleOneShotPtt(composeScope: CoroutineScope, vm: WorkspaceViewModel) {
        composeScope.launch {
            continuousEngine.disable()
            pttEngine.startRecording()
            kotlinx.coroutines.delay(2_000)
            val text = pttEngine.stopAndProcess(settings.currentSpeechOptions())
            if (text != null) vm.sendInput(text)
            if (settings.continuousListeningEnabled.value) continuousEngine.enable()
        }
    }

    /** Stops listening + the foreground service. Called on workspace teardown. */
    fun stop() {
        continuousEngine.disable()
        pttEngine.cancel()
        ContinuousListeningService.Bridge.onUtterance = null
        ContinuousListeningService.stop(appContext)
    }

    companion object {
        fun create(context: Context, scope: CoroutineScope, settings: AppSettings): SpeechSession {
            val appContext = context.applicationContext
            val store = SpeechModelStore.create(appContext)
            val postProcessor = SpeechPostProcessor(cleaner = TextCleaner(), enhancer = CloudPromptEnhancer())

            // Device-deferred: the real Oboe/AudioRecord capture is M3-F device work.
            val ptt = OnDeviceSpeechEngine.makeDefault(
                capture = NoOpAudioCapture,
                postProcessor = postProcessor,
            )
            val continuous = ContinuousListeningEngine.makeDefault(
                scope = scope,
                options = settings.currentSpeechOptions(),
                postProcessor = postProcessor,
                // audioSource = null → device-deferred mic; the engine still drives
                // its state machine when fed audio (none until the M3-F mic lands).
            )
            return SpeechSession(appContext, scope, settings, store, ptt, continuous)
        }

        /**
         * Stub capture so [OnDeviceSpeechEngine] constructs without the
         * device-deferred microphone. `stop()` returns null → the PTT engine
         * treats it as "no output" rather than crashing. Replaced by the real
         * Oboe/AudioRecord capture in M3-F.
         */
        private object NoOpAudioCapture : AudioCapturing {
            override val isRecording: Boolean = false
            override fun start() = Unit
            override fun stop(): FloatArray? = null
        }
    }
}
