import XCTest
@testable import CodeRelaySpeech

@MainActor
final class TurnEndDetectorTests: XCTestCase {

    func testHeuristicAlwaysReturnsSpeakerDone() async {
        let detector = HeuristicTurnEndDetector()
        let audio = Array(repeating: Float(0.2), count: 16000)

        let result = await detector.predict(utteranceAudio: audio)
        XCTAssertEqual(result, .speakerDone(confidence: 1.0))
    }

    func testHeuristicHandlesShortAudio() async {
        let detector = HeuristicTurnEndDetector()
        let audio = Array(repeating: Float(0.1), count: 100)

        let result = await detector.predict(utteranceAudio: audio)
        XCTAssertEqual(result, .speakerDone(confidence: 1.0))
    }

    func testHeuristicHandlesEmptyAudio() async {
        let detector = HeuristicTurnEndDetector()
        let result = await detector.predict(utteranceAudio: [])
        XCTAssertEqual(result, .speakerDone(confidence: 1.0))
    }

    func testTurnEndResultEquatable() {
        XCTAssertEqual(
            TurnEndResult.speakerDone(confidence: 0.9),
            TurnEndResult.speakerDone(confidence: 0.9)
        )
        XCTAssertNotEqual(
            TurnEndResult.speakerDone(confidence: 0.9),
            TurnEndResult.speakerContinuing(confidence: 0.9)
        )
    }
}
