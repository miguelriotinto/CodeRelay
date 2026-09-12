import XCTest
@testable import CodeRelaySpeech

final class VADEventTests: XCTestCase {

    func testIsSpeechTrueForSpeechEvents() {
        XCTAssertTrue(VADEvent.speechStart.isSpeech)
        XCTAssertTrue(VADEvent.speechContinue.isSpeech)
    }

    func testIsSpeechFalseForSilenceEvents() {
        XCTAssertFalse(VADEvent.silenceStart.isSpeech)
        XCTAssertFalse(VADEvent.silenceContinue.isSpeech)
    }

    func testIsEdgeTrueForStartEvents() {
        XCTAssertTrue(VADEvent.speechStart.isEdge)
        XCTAssertTrue(VADEvent.silenceStart.isEdge)
    }

    func testIsEdgeFalseForContinueEvents() {
        XCTAssertFalse(VADEvent.speechContinue.isEdge)
        XCTAssertFalse(VADEvent.silenceContinue.isEdge)
    }
}
