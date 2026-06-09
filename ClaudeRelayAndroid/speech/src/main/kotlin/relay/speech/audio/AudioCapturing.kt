package relay.speech.audio

/**
 * Contract for the push-to-talk accumulating microphone capture.
 *
 * Mirrors Swift `AudioCaptureSession` (the surface used by `OnDeviceSpeechEngine`):
 * [start] begins buffering 16 kHz mono Float32 samples; [stop] ends capture and
 * returns the accumulated buffer (or `null` when too short / empty per the
 * minimum-duration floor).
 *
 * **The production microphone implementation is device-deferred** — see
 * [AudioCaptureContract] for the Oboe/AudioRecord + resampler contract, the 5 min
 * `maximumDuration` cap, and the 0.5 s `minimumDuration` floor. This interface
 * exists so [relay.speech.OnDeviceSpeechEngine] can be driven by a fake capture
 * in unit tests.
 */
interface AudioCapturing {
    /** True while actively buffering samples. */
    val isRecording: Boolean

    /** Begin capture. Throws if the mic is unavailable. */
    fun start()

    /**
     * End capture and return the accumulated 16 kHz mono buffer, or `null` if the
     * capture was too short / empty (below the minimum-duration floor).
     */
    fun stop(): FloatArray?
}
