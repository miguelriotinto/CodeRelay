import Foundation
import os.log

private let log = Logger(subsystem: "com.coderelay.speech", category: "VAD")

/// Energy-based voice activity detector with hysteresis and debouncing.
///
/// Baseline implementation using RMS energy as the speech/silence signal —
/// simple and dependency-free. The CoreML-backed `SileroVoiceActivityDetector`
/// can substitute its probability output for the energy score while reusing
/// the same state machine.
///
/// Processes 30 ms chunks (480 samples at 16 kHz).
public final class VoiceActivityDetector: VoiceActivityDetecting, @unchecked Sendable {

    public struct Config {
        /// RMS energy above this = speech.
        public var speechThreshold: Float = 0.015
        /// RMS energy below this = silence. Between thresholds = hysteresis hold.
        public var silenceThreshold: Float = 0.008
        /// Chunk duration — fixed to 30 ms at 16 kHz.
        public var chunkDurationSeconds: TimeInterval = 0.030
        /// Minimum sustained speech before emitting speechStart.
        public var minSpeechDuration: TimeInterval = 0.25
        /// Minimum sustained silence before emitting silenceStart.
        // 1.0s filters breath pauses (400-800ms) — turn-end classifier decides actual completion
        public var minSilenceDuration: TimeInterval = 1.0

        public init() {}
    }

    public enum InternalState { case silent, speaking }

    public let config: Config
    private var state: InternalState = .silent

    private var pendingSpeechChunks: Int = 0
    private var pendingSilenceChunks: Int = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    private var processCount: Int = 0
    private var lastLoggedProcessCount: Int = 0

    public func process(chunk: [Float]) -> VADEvent {
        processCount += 1
        let energy = Self.rms(chunk)
        let signal: Bool = Self.scoreToBool(
            energy: energy,
            state: state,
            speechThreshold: config.speechThreshold,
            silenceThreshold: config.silenceThreshold
        )
        let result = transition(signalIsSpeech: signal)

        // Log every 50 chunks (~1.5s) to show energy levels, or always on edge events
        if result.isEdge {
            log.info("VAD EDGE: \(String(describing: result)) | energy=\(String(format: "%.5f", energy)) speechThresh=\(self.config.speechThreshold) silenceThresh=\(self.config.silenceThreshold) pending_speech=\(self.pendingSpeechChunks) pending_silence=\(self.pendingSilenceChunks)")
        } else if processCount - lastLoggedProcessCount >= 50 {
            log.debug("VAD: energy=\(String(format: "%.5f", energy)) state=\(String(describing: self.state)) signal=\(signal) pending_speech=\(self.pendingSpeechChunks) pending_silence=\(self.pendingSilenceChunks)")
            lastLoggedProcessCount = processCount
        }

        return result
    }

    public func reset() {
        state = .silent
        pendingSpeechChunks = 0
        pendingSilenceChunks = 0
    }

    // MARK: - Internals

    /// Root-mean-square of a chunk. Allocation-free.
    static func rms(_ chunk: [Float]) -> Float {
        if chunk.isEmpty { return 0 }
        var sumSquares: Float = 0
        for sample in chunk {
            sumSquares += sample * sample
        }
        return (sumSquares / Float(chunk.count)).squareRoot()
    }

    /// Hysteresis-aware speech/silence decision.
    static func scoreToBool(
        energy: Float,
        state: InternalState,
        speechThreshold: Float,
        silenceThreshold: Float
    ) -> Bool {
        switch state {
        case .silent:  return energy >= speechThreshold
        case .speaking: return energy >= silenceThreshold
        }
    }

    private func transition(signalIsSpeech: Bool) -> VADEvent {
        let minSpeechChunks = chunks(for: config.minSpeechDuration)
        let minSilenceChunks = chunks(for: config.minSilenceDuration)

        switch state {
        case .silent:
            if signalIsSpeech {
                pendingSpeechChunks += 1
                if pendingSpeechChunks >= minSpeechChunks {
                    state = .speaking
                    pendingSpeechChunks = 0
                    pendingSilenceChunks = 0
                    return .speechStart
                }
                return .silenceContinue  // still silent (debouncing)
            } else {
                pendingSpeechChunks = 0
                return .silenceContinue
            }

        case .speaking:
            if signalIsSpeech {
                pendingSilenceChunks = 0
                return .speechContinue
            } else {
                pendingSilenceChunks += 1
                if pendingSilenceChunks >= minSilenceChunks {
                    state = .silent
                    pendingSilenceChunks = 0
                    pendingSpeechChunks = 0
                    return .silenceStart
                }
                return .speechContinue  // still speaking (debouncing)
            }
        }
    }

    private func chunks(for duration: TimeInterval) -> Int {
        max(1, Int(duration / config.chunkDurationSeconds))
    }
}
