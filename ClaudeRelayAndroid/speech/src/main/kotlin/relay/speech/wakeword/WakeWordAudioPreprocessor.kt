package relay.speech.wakeword

import kotlin.math.abs

/**
 * Audio preprocessing applied before Whisper transcription of wake-word clips.
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/WakeWordAudioPreprocessor.swift`.
 *
 * Whisper is trained on 30-second clips at conversational volume. A short,
 * quiet "Claude" looks nothing like that distribution. Two cheap fixes:
 *
 *   1. **Peak-normalize** so a softly-spoken wake word has the same amplitude
 *      as a loudly-spoken one. The single biggest recognition-accuracy win for
 *      short wake words.
 *   2. **Pad with silence** to a few seconds so Whisper's encoder isn't looking
 *      at a ~0.8s clip embedded in implicit silence (which trips its internal
 *      VAD-like gates).
 */
object WakeWordAudioPreprocessor {

    /**
     * Samples below this absolute value are treated as noise floor and will not
     * trigger normalization (avoids boosting silence to full scale). ~-66 dBFS.
     */
    private const val NOISE_FLOOR: Float = 0.001f

    /** Target peak after normalization. Not quite 1.0 to leave headroom. */
    private const val TARGET_PEAK: Float = 0.95f

    /**
     * Scale [samples] so their absolute peak equals [TARGET_PEAK], unless the
     * whole buffer is below the noise floor (in which case return unchanged).
     */
    fun peakNormalize(samples: FloatArray): FloatArray {
        if (samples.isEmpty()) return samples

        var peak = 0f
        for (sample in samples) {
            val absoluteValue = abs(sample)
            if (absoluteValue > peak) peak = absoluteValue
        }

        if (peak <= NOISE_FLOOR) return samples

        val scale = TARGET_PEAK / peak
        return FloatArray(samples.size) { samples[it] * scale }
    }

    /**
     * Pad [samples] with trailing zeros (silence) until the buffer is at least
     * [seconds] long at [sampleRate]. Longer buffers are returned unchanged —
     * this function never truncates.
     */
    fun pad(samples: FloatArray, toSeconds: Double, sampleRate: Double): FloatArray {
        val targetSampleCount = (toSeconds * sampleRate).toInt()
        if (samples.size >= targetSampleCount) return samples

        val padded = FloatArray(targetSampleCount)
        samples.copyInto(padded)
        // Remaining entries are already 0f (FloatArray default).
        return padded
    }
}
