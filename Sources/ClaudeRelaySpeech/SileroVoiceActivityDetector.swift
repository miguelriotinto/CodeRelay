import Foundation
import CoreML
import os.log

private let log = Logger(subsystem: "com.claude.relay.speech", category: "SileroVAD")

/// CoreML-backed voice activity detector using the Silero VAD v6 "unified"
/// model (STFT + Encoder + Decoder bundled, with stateful LSTM).
///
/// The model takes a 576-sample input (64-sample context + 512 new samples)
/// along with LSTM hidden/cell state [1, 128], and returns a probability
/// plus updated state. This wrapper:
///   - Buffers variable-size audio tap chunks into 512-sample inference windows
///   - Threads LSTM state (`h`, `c`) and audio context across calls
///   - Feeds the probability into `VoiceActivityDetector`'s debounce state machine
///
/// Falls back gracefully: if the bundled model fails to load or validate, init
/// returns nil and callers substitute the energy-based detector.
public final class SileroVoiceActivityDetector: VoiceActivityDetecting, @unchecked Sendable {

    /// New audio samples per inference window.
    public static let chunkSamples = 512
    /// Context samples prepended to each chunk (from the previous window's tail).
    private static let contextSize = 64
    /// Total model input size: context + chunk.
    private static let modelInputSize = contextSize + chunkSamples
    /// LSTM hidden/cell state dimension.
    private static let stateSize = 128

    private let inner: VoiceActivityDetector
    private let model: MLModel

    /// Residual samples not yet consumed by a 512-sample inference window.
    private var residual: [Float] = []

    /// Last probability produced by the model.
    private var lastProbability: Float = 0.0

    // LSTM state threaded across inference calls
    private var hiddenState: [Float]
    private var cellState: [Float]
    /// Trailing context from the previous chunk (last 64 samples).
    private var context: [Float]

    public convenience init?(config: VoiceActivityDetector.Config = .init()) {
        guard let url = Bundle.module.url(forResource: "SileroVAD", withExtension: "mlmodelc") else {
            log.warning("SileroVAD: mlmodelc not found in bundle — falling back to energy VAD")
            return nil
        }
        guard let loaded = try? MLModel(contentsOf: url) else {
            log.error("SileroVAD: failed to load MLModel from \(url.path)")
            return nil
        }

        // Validate the model accepts stateful inputs (hidden_state, cell_state)
        let inputNames = Set(loaded.modelDescription.inputDescriptionsByName.keys)
        guard inputNames.contains("hidden_state"), inputNames.contains("cell_state") else {
            log.error("SileroVAD: model missing hidden_state/cell_state inputs — not a stateful unified model. Falling back to energy VAD.")
            return nil
        }

        log.info("SileroVAD: unified v6 model loaded (stateful LSTM, \(Self.modelInputSize)-sample input)")
        self.init(model: loaded, config: config)
    }

    init(model: MLModel, config: VoiceActivityDetector.Config) {
        self.model = model
        self.hiddenState = [Float](repeating: 0, count: Self.stateSize)
        self.cellState = [Float](repeating: 0, count: Self.stateSize)
        self.context = [Float](repeating: 0, count: Self.contextSize)

        var cfg = config
        cfg.speechThreshold = 0.5
        cfg.silenceThreshold = 0.35
        // The audio source delivers ~1600-sample chunks (~100ms at 16kHz).
        // The inner VAD uses chunkDurationSeconds to compute debounce chunk
        // counts. Without this correction, the 30ms default inflates the real
        // debounce from 250ms to ~800ms, causing the wake word to be spoken
        // and gone before speechStart fires.
        cfg.chunkDurationSeconds = 0.1
        self.inner = VoiceActivityDetector(config: cfg)
        self.residual.reserveCapacity(Self.chunkSamples * 2)
    }

    private var sileroProcessCount: Int = 0

    public func process(chunk: [Float]) -> VADEvent {
        sileroProcessCount += 1
        residual.append(contentsOf: chunk)
        while residual.count >= Self.chunkSamples {
            let window = Array(residual.prefix(Self.chunkSamples))
            residual.removeFirst(Self.chunkSamples)
            lastProbability = predict(window: window)
        }

        let syntheticChunkSize = max(chunk.count, 1)
        let result = inner.process(chunk: Array(repeating: lastProbability, count: syntheticChunkSize))

        if result.isEdge {
            log.info("SileroVAD EDGE: \(String(describing: result)) prob=\(String(format: "%.3f", self.lastProbability))")
        } else if sileroProcessCount % 100 == 0 {
            log.debug("SileroVAD: prob=\(String(format: "%.3f", self.lastProbability)) chunk#\(self.sileroProcessCount)")
        }

        return result
    }

    public func reset() {
        inner.reset()
        residual.removeAll(keepingCapacity: true)
        lastProbability = 0.0
        hiddenState = [Float](repeating: 0, count: Self.stateSize)
        cellState = [Float](repeating: 0, count: Self.stateSize)
        context = [Float](repeating: 0, count: Self.contextSize)
    }

    // MARK: - Internals

    private func predict(window: [Float]) -> Float {
        guard window.count == Self.chunkSamples else { return lastProbability }
        do {
            // Build audio_input: [1, 576] = context (64) + new audio (512)
            let audioInput = try MLMultiArray(
                shape: [1, NSNumber(value: Self.modelInputSize)],
                dataType: .float32
            )
            let audioPtr = audioInput.dataPointer.assumingMemoryBound(to: Float.self)
            context.withUnsafeBufferPointer { src in
                audioPtr.update(from: src.baseAddress!, count: Self.contextSize)
            }
            window.withUnsafeBufferPointer { src in
                (audioPtr + Self.contextSize).update(from: src.baseAddress!, count: Self.chunkSamples)
            }

            // Build hidden_state: [1, 128]
            let hInput = try MLMultiArray(
                shape: [1, NSNumber(value: Self.stateSize)],
                dataType: .float32
            )
            let hPtr = hInput.dataPointer.assumingMemoryBound(to: Float.self)
            hiddenState.withUnsafeBufferPointer { src in
                hPtr.update(from: src.baseAddress!, count: Self.stateSize)
            }

            // Build cell_state: [1, 128]
            let cInput = try MLMultiArray(
                shape: [1, NSNumber(value: Self.stateSize)],
                dataType: .float32
            )
            let cPtr = cInput.dataPointer.assumingMemoryBound(to: Float.self)
            cellState.withUnsafeBufferPointer { src in
                cPtr.update(from: src.baseAddress!, count: Self.stateSize)
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": audioInput,
                "hidden_state": hInput,
                "cell_state": cInput
            ])
            let output = try model.prediction(from: provider)

            // Extract probability
            var prob = lastProbability
            if let vadOut = output.featureValue(for: "vad_output")?.multiArrayValue, vadOut.count > 0 {
                prob = Float(truncating: vadOut[0])
            }

            // Thread LSTM state for next call
            if let newH = output.featureValue(for: "new_hidden_state")?.multiArrayValue {
                let ptr = newH.dataPointer.assumingMemoryBound(to: Float.self)
                hiddenState = Array(UnsafeBufferPointer(start: ptr, count: Self.stateSize))
            }
            if let newC = output.featureValue(for: "new_cell_state")?.multiArrayValue {
                let ptr = newC.dataPointer.assumingMemoryBound(to: Float.self)
                cellState = Array(UnsafeBufferPointer(start: ptr, count: Self.stateSize))
            }

            // Update context with tail of current window
            context = Array(window.suffix(Self.contextSize))

            return prob
        } catch {
            log.error("SileroVAD prediction failed: \(error.localizedDescription)")
            return lastProbability
        }
    }
}
