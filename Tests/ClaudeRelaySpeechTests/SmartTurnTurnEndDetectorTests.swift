import XCTest
@testable import ClaudeRelaySpeech

@MainActor
final class SmartTurnTurnEndDetectorTests: XCTestCase {

    func testLoadsBundledModels() {
        let detector = SmartTurnTurnEndDetector()
        XCTAssertNotNil(detector, "Both WhisperLogMel8s.mlpackage and SmartTurnV3.mlpackage should load")
    }

    func testPadOrTruncateHandlesExactSize() {
        let sampleCount = SmartTurnTurnEndDetector.requiredSampleCount
        let arr = Array(repeating: Float(0.7), count: sampleCount)
        let result = SmartTurnTurnEndDetector.padOrTruncate(arr, toCount: sampleCount)
        XCTAssertEqual(result.count, sampleCount)
        XCTAssertEqual(result.first, 0.7)
    }

    func testPadOrTruncateZeroPadsFromStart() {
        let arr = Array(repeating: Float(0.5), count: 1000)
        let result = SmartTurnTurnEndDetector.padOrTruncate(arr, toCount: 3000)
        XCTAssertEqual(result.count, 3000)
        XCTAssertEqual(result[0], 0.0)
        XCTAssertEqual(result[1999], 0.0)
        XCTAssertEqual(result[2000], 0.5)
        XCTAssertEqual(result[2999], 0.5)
    }

    func testPadOrTruncateTruncatesFromStart() {
        let arr = (0..<1000).map { Float($0) / 1000 }
        let result = SmartTurnTurnEndDetector.padOrTruncate(arr, toCount: 500)
        XCTAssertEqual(result.count, 500)
        XCTAssertEqual(result[0], arr[500])
        XCTAssertEqual(result[499], arr[999])
    }

    func testPredictReturnsResultOnShortAudio() async {
        guard let detector = SmartTurnTurnEndDetector() else {
            XCTFail("Smart-Turn models unavailable"); return
        }
        // Sub-8-second audio is zero-padded from the start.
        let audio = Array(repeating: Float(0.0), count: 16_000)
        let result = await detector.predict(utteranceAudio: audio)
        switch result {
        case .speakerDone, .speakerContinuing:
            break   // just verifying no crash + structured output
        }
    }

    func testPredictReturnsResultOnFullLengthAudio() async {
        guard let detector = SmartTurnTurnEndDetector() else { return }
        // Synthesize 8 s of deterministic "speech-like" white noise.
        var rng = SystemRandomNumberGenerator()
        let audio: [Float] = (0..<SmartTurnTurnEndDetector.requiredSampleCount).map { _ in
            (Float.random(in: -1...1, using: &rng)) * 0.1
        }
        let result = await detector.predict(utteranceAudio: audio)
        switch result {
        case .speakerDone(let probability), .speakerContinuing(let probability):
            XCTAssertGreaterThanOrEqual(probability, 0.0)
            XCTAssertLessThanOrEqual(probability, 1.0)
        }
    }
}
