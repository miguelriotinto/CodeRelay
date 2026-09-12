package relay.speech.transcribe

/**
 * Contract for transcribing 16 kHz mono Float32 audio into text.
 *
 * Mirrors Swift `SpeechTranscribing`. Extracted as an interface so the
 * orchestrators ([relay.speech.OnDeviceSpeechEngine],
 * [relay.speech.ContinuousListeningEngine]) and the wake-word check can inject a
 * fake transcriber in unit tests without the native whisper.cpp bridge.
 *
 * The production implementation is the device-deferred whisper.cpp JNI path
 * documented in [WhisperTranscriber.transcribe]; a thin adapter ([whisperAdapter])
 * forwards to it so the singleton `object` can satisfy this interface.
 */
fun interface SpeechTranscribing {
    /**
     * Transcribe the buffer. [skipNoSpeechFilter] disables Whisper's no-speech
     * threshold when VAD has already confirmed speech. Throws on empty / failure
     * (e.g. [TranscriberError.EmptyTranscription], [TranscriberError.ModelNotLoaded]).
     */
    suspend fun transcribe(audioBuffer: FloatArray, skipNoSpeechFilter: Boolean): String
}

/**
 * Adapts the [WhisperTranscriber] singleton `object` to the [SpeechTranscribing]
 * interface for production wiring. The native inference is still the deferred
 * EXECUTION NOTE in [WhisperTranscriber.transcribe].
 */
fun whisperAdapter(): SpeechTranscribing = SpeechTranscribing { audio, skipNoSpeechFilter ->
    WhisperTranscriber.transcribe(audio, skipNoSpeechFilter)
}
