import XCTest
@testable import ClaudeRelaySpeech

final class WakeWordAudioPreprocessorTests: XCTestCase {

    // MARK: - Peak normalization

    func testPeakNormalizeBoostsQuietAudio() {
        // Quiet clip: peak at 0.05
        let quiet: [Float] = [0.0, 0.05, -0.04, 0.02, -0.01]
        let result = WakeWordAudioPreprocessor.peakNormalize(quiet)

        let peak = result.map { abs($0) }.max() ?? 0
        XCTAssertEqual(peak, 0.95, accuracy: 0.001, "Peak should be scaled to ~0.95")
    }

    func testPeakNormalizePreservesRelativeShape() {
        let samples: [Float] = [0.1, -0.05, 0.02, -0.1]
        let result = WakeWordAudioPreprocessor.peakNormalize(samples)

        // Scale factor is 0.95 / 0.1 = 9.5
        XCTAssertEqual(result[0], 0.95, accuracy: 0.001)
        XCTAssertEqual(result[1], -0.475, accuracy: 0.001)
        XCTAssertEqual(result[2], 0.19, accuracy: 0.001)
        XCTAssertEqual(result[3], -0.95, accuracy: 0.001)
    }

    func testPeakNormalizeLeavesLoudAudioAlone() {
        // Already near full scale — don't amplify further.
        let loud: [Float] = [0.95, -0.93, 0.90]
        let result = WakeWordAudioPreprocessor.peakNormalize(loud)

        let peak = result.map { abs($0) }.max() ?? 0
        XCTAssertEqual(peak, 0.95, accuracy: 0.001)
        // First sample was already 0.95, should be unchanged
        XCTAssertEqual(result[0], 0.95, accuracy: 0.001)
    }

    func testPeakNormalizeIgnoresSilence() {
        // All zeros — do nothing, don't divide by zero.
        let silent = [Float](repeating: 0.0, count: 100)
        let result = WakeWordAudioPreprocessor.peakNormalize(silent)

        XCTAssertEqual(result, silent)
    }

    func testPeakNormalizeIgnoresBelowFloor() {
        // Below the noise floor — leave alone to avoid amplifying hum/hiss
        // to full scale when there's no real speech.
        let noise: [Float] = [0.0005, -0.0003, 0.0008, -0.0002]
        let result = WakeWordAudioPreprocessor.peakNormalize(noise)

        // Should be unchanged — too quiet to be real speech.
        XCTAssertEqual(result, noise)
    }

    func testPeakNormalizeHandlesEmptyBuffer() {
        let empty: [Float] = []
        XCTAssertEqual(WakeWordAudioPreprocessor.peakNormalize(empty), [])
    }

    // MARK: - Padding

    func testPadAddsTrailingSilence() {
        let samples = [Float](repeating: 0.1, count: 16000)  // 1s @ 16kHz
        let padded = WakeWordAudioPreprocessor.pad(samples, toSeconds: 3.0, sampleRate: 16000)

        XCTAssertEqual(padded.count, 48000, "Should be padded to 3s = 48000 samples")
        // Original samples should be at the start
        XCTAssertEqual(padded[0], 0.1)
        XCTAssertEqual(padded[15999], 0.1)
        // Trailing samples should be silence
        XCTAssertEqual(padded[16000], 0.0)
        XCTAssertEqual(padded[47999], 0.0)
    }

    func testPadLeavesAudioAlreadyAtLengthAlone() {
        let samples = [Float](repeating: 0.1, count: 48000)  // 3s
        let padded = WakeWordAudioPreprocessor.pad(samples, toSeconds: 3.0, sampleRate: 16000)

        XCTAssertEqual(padded.count, 48000)
        XCTAssertEqual(padded, samples)
    }

    func testPadLeavesLongerAudioAlone() {
        let samples = [Float](repeating: 0.1, count: 64000)  // 4s
        let padded = WakeWordAudioPreprocessor.pad(samples, toSeconds: 3.0, sampleRate: 16000)

        XCTAssertEqual(padded.count, 64000, "Padding shouldn't truncate")
        XCTAssertEqual(padded, samples)
    }

    func testPadHandlesEmptyBuffer() {
        let padded = WakeWordAudioPreprocessor.pad([], toSeconds: 1.0, sampleRate: 16000)
        XCTAssertEqual(padded.count, 16000)
        XCTAssertTrue(padded.allSatisfy { $0 == 0 })
    }
}
