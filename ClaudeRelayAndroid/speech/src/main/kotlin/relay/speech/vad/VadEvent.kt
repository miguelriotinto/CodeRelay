package relay.speech.vad

/**
 * Events emitted by a voice activity detector per audio chunk.
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/VADEvent.swift`. Four cases —
 * the start/continue distinction for both speech and silence lets callers act
 * only on edges (segment boundaries) while still receiving per-chunk signals.
 */
enum class VadEvent {
    /** First chunk of a speech segment. */
    SpeechStart,

    /** Subsequent speech chunk. */
    SpeechContinue,

    /** First chunk of silence after speech. */
    SilenceStart,

    /** Ongoing silence. */
    SilenceContinue;

    val isSpeech: Boolean
        get() = when (this) {
            SpeechStart, SpeechContinue -> true
            SilenceStart, SilenceContinue -> false
        }

    /** True for start-of-segment events; callers usually only act on these. */
    val isEdge: Boolean
        get() = when (this) {
            SpeechStart, SilenceStart -> true
            SpeechContinue, SilenceContinue -> false
        }
}

/**
 * Contract for voice activity detection — enables mock injection in tests and
 * substituting a model-backed detector for the energy baseline.
 *
 * Mirrors the Swift `VoiceActivityDetecting` protocol.
 */
interface VoiceActivityDetecting {
    /** Process one audio chunk and return the resulting event. */
    fun process(chunk: FloatArray): VadEvent

    /** Reset internal state (e.g., recurrent hidden state, debounce counters). */
    fun reset()
}
