import Foundation
import CoreML

/// CoreML-backed turn-end detector wrapping pipecat-ai/smart-turn v3.2.
///
/// Pipeline:
///   audio (≤8 s, 16 kHz mono) → pad/truncate to 128 000 samples
///       → WhisperLogMel8s (log-mel features [1, 80, 800])
///       → SmartTurnV3 (Whisper Tiny encoder + linear head, outputs sigmoid)
///       → probability in [0, 1]
///
/// Above `threshold`, the speaker is considered done. Falls back gracefully:
/// if either CoreML model fails to load, the init returns nil and callers
/// substitute `HeuristicTurnEndDetector`.
public final class SmartTurnTurnEndDetector: TurnEndDetecting, @unchecked Sendable {

    /// 8 s at 16 kHz — the model's fixed input length.
    public static let requiredSampleCount = 128_000

    private let preprocessor: MLModel
    private let classifier: MLModel
    private let threshold: Float

    public convenience init?(threshold: Float = 0.5) {
        guard let preURL = Bundle.module.url(forResource: "WhisperLogMel8s",
                                             withExtension: "mlpackage"),
              let stURL = Bundle.module.url(forResource: "SmartTurnV3",
                                            withExtension: "mlpackage"),
              let pre = Self.loadModel(at: preURL),
              let st = Self.loadModel(at: stURL) else {
            return nil
        }
        self.init(preprocessor: pre, classifier: st, threshold: threshold)
    }

    // Cache compiled model — initial compile takes seconds, reuse is instant
    private static func loadModel(at url: URL) -> MLModel? {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory,
                                                 in: .userDomainMask).first
        let cacheName = url.deletingPathExtension().lastPathComponent + ".mlmodelc"
        let cachedURL = cachesDir?.appendingPathComponent(cacheName)

        // If we have a cached compiled copy, use it directly.
        if let cachedURL, FileManager.default.fileExists(atPath: cachedURL.path) {
            if let model = try? MLModel(contentsOf: cachedURL) {
                return model
            }
        }

        // Otherwise, compile the .mlpackage to a temp location, then copy into cache.
        guard let compiledURL = try? MLModel.compileModel(at: url) else {
            return nil
        }
        if let cachedURL = cachedURL {
            try? FileManager.default.removeItem(at: cachedURL)
            try? FileManager.default.moveItem(at: compiledURL, to: cachedURL)
            if let model = try? MLModel(contentsOf: cachedURL) {
                return model
            }
        }
        return try? MLModel(contentsOf: compiledURL)
    }

    init(preprocessor: MLModel, classifier: MLModel, threshold: Float) {
        self.preprocessor = preprocessor
        self.classifier = classifier
        self.threshold = threshold
    }

    public func predict(utteranceAudio: [Float]) async -> TurnEndResult {
        let padded = Self.padOrTruncate(utteranceAudio, toCount: Self.requiredSampleCount)
        let probability = infer(audio: padded)
        return probability >= threshold
            ? .speakerDone(confidence: probability)
            : .speakerContinuing(confidence: 1.0 - probability)
    }

    // MARK: - Helpers

    /// Take the last 8 s of audio; zero-pad at the start if shorter.
    /// Smart-Turn expects the newest audio at the end of the window.
    static func padOrTruncate(_ samples: [Float], toCount n: Int) -> [Float] {
        if samples.count == n { return samples }
        if samples.count > n { return Array(samples.suffix(n)) }
        var out = Array(repeating: Float(0), count: n - samples.count)
        out.append(contentsOf: samples)
        return out
    }

    private func infer(audio: [Float]) -> Float {
        do {
            // Step 1: audio → log-mel features [1, 80, 800]
            let audioArray = try MLMultiArray(
                shape: [NSNumber(value: Self.requiredSampleCount)],
                dataType: .float32
            )
            for i in 0..<audio.count {
                audioArray[i] = NSNumber(value: audio[i])
            }
            let preProvider = try MLDictionaryFeatureProvider(dictionary: ["audio": audioArray])
            let preOutput = try preprocessor.prediction(from: preProvider)
            guard let features = preOutput.featureValue(for: "log_mel")?.multiArrayValue else {
                return 1.0   // default to "done" on error to avoid stalling
            }

            // Step 2: log-mel → probability [1, 1]
            let stProvider = try MLDictionaryFeatureProvider(dictionary: ["input_features": features])
            let stOutput = try classifier.prediction(from: stProvider)
            if let prob = stOutput.featureValue(for: "probability")?.multiArrayValue,
               prob.count > 0 {
                return Float(truncating: prob[0])
            }
            return 1.0
        } catch {
            return 1.0
        }
    }
}
