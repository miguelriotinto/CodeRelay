import Foundation

/// Audio preprocessing applied before Whisper transcription of wake-word clips.
///
/// Whisper is trained on 30-second clips at conversational volume. A short,
/// quiet "Claude" looks nothing like that distribution. Two cheap fixes:
///
///   1. **Peak-normalize** so a softly-spoken wake word has the same
///      amplitude as a loudly-spoken one. This is the single biggest
///      recognition-accuracy win for short wake words.
///   2. **Pad with silence** to a few seconds so Whisper's encoder isn't
///      looking at a ~0.8s clip embedded in ~30s of implicit silence
///      (which triggers its internal VAD-like gates).
public enum WakeWordAudioPreprocessor {

    /// Samples below this absolute value are treated as noise floor and
    /// will not trigger normalization (avoids boosting silence to full scale).
    /// Roughly -66 dBFS.
    private static let noiseFloor: Float = 0.001

    /// Target peak after normalization. Not quite 1.0 to leave headroom.
    private static let targetPeak: Float = 0.95

    /// Scale `samples` so their absolute peak equals `targetPeak`, unless the
    /// whole buffer is below the noise floor (in which case return unchanged).
    public static func peakNormalize(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }

        var peak: Float = 0
        for sample in samples {
            let absoluteValue = abs(sample)
            if absoluteValue > peak { peak = absoluteValue }
        }

        guard peak > noiseFloor else { return samples }

        let scale = targetPeak / peak
        return samples.map { $0 * scale }
    }

    /// Pad `samples` with trailing zeros (silence) until the buffer is at
    /// least `toSeconds` long at `sampleRate`. Longer buffers are returned
    /// unchanged — this function never truncates.
    public static func pad(
        _ samples: [Float],
        toSeconds seconds: TimeInterval,
        sampleRate: Double
    ) -> [Float] {
        let targetSampleCount = Int(seconds * sampleRate)
        guard samples.count < targetSampleCount else { return samples }

        var padded = samples
        padded.append(contentsOf: [Float](repeating: 0, count: targetSampleCount - samples.count))
        return padded
    }
}
