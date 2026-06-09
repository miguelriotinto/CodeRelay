package relay.speech.audio

/**
 * Audio-focus interruption event surfaced by a [StreamingAudioSourcing].
 *
 * Mirrors Swift `StreamingAudioSource.InterruptionEvent`. On Android the
 * device-deferred implementation maps `AudioManager.OnAudioFocusChangeListener`
 * focus changes onto these cases (see [AudioCaptureContract]).
 */
sealed interface AudioInterruptionEvent {
    /** Capture should pause (focus loss). */
    data object Began : AudioInterruptionEvent

    /** Focus regained; [shouldResume] tells the engine whether to re-enable. */
    data class Ended(val shouldResume: Boolean) : AudioInterruptionEvent
}

/**
 * Contract for a streaming microphone source that pushes 16 kHz mono Float32
 * chunks. Mirrors Swift `StreamingAudioSourcing`.
 *
 * **The production microphone implementation is device-deferred** — see
 * [AudioCaptureContract]. This interface exists so [relay.speech.ContinuousListeningEngine]
 * can be driven by a fake source in unit tests (start/stop accounting and
 * interruption handling) and wired to the real Oboe/AudioRecord capture later.
 *
 * The engine sets [onChunk] / [onInterruption] in its constructor; the source
 * invokes them as audio flows / focus changes.
 */
interface StreamingAudioSourcing {
    /** Set by the consumer; invoked once per converted 16 kHz chunk. */
    var onChunk: ((FloatArray) -> Unit)?

    /** Set by the consumer; invoked on audio-focus interruptions. */
    var onInterruption: ((AudioInterruptionEvent) -> Unit)?

    /** Start capturing. Throws if the mic is unavailable. */
    fun start()

    /** Stop capturing. */
    fun stop()
}
