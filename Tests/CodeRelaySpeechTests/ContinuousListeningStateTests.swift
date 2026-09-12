import XCTest
@testable import CodeRelaySpeech

final class ContinuousListeningStateTests: XCTestCase {

    func testIsActiveReturnsFalseForIdle() {
        XCTAssertFalse(ContinuousListeningState.idle.isActive)
    }

    func testIsActiveReturnsTrueForListening() {
        XCTAssertTrue(ContinuousListeningState.listening.isActive)
    }

    func testIsActiveReturnsTrueForRecording() {
        XCTAssertTrue(ContinuousListeningState.recording.isActive)
    }

    func testIsCapturingReturnsTrueForRecording() {
        XCTAssertTrue(ContinuousListeningState.recording.isCapturing)
    }

    func testIsCapturingReturnsTrueForDetectingTurnEnd() {
        XCTAssertTrue(ContinuousListeningState.detectingTurnEnd.isCapturing)
    }

    func testIsCapturingReturnsFalseForListening() {
        XCTAssertFalse(ContinuousListeningState.listening.isCapturing)
    }

    func testIsArmedBuckets() {
        XCTAssertTrue(ContinuousListeningState.armed.isArmed)
        XCTAssertTrue(ContinuousListeningState.recording.isArmed)
        XCTAssertTrue(ContinuousListeningState.detectingTurnEnd.isArmed)
        XCTAssertFalse(ContinuousListeningState.listening.isArmed)
        XCTAssertFalse(ContinuousListeningState.detectingWakeWord.isArmed)
        XCTAssertFalse(ContinuousListeningState.transcribing.isArmed)
    }

    func testArmedIsActiveButNotCapturing() {
        XCTAssertTrue(ContinuousListeningState.armed.isActive)
        XCTAssertFalse(ContinuousListeningState.armed.isCapturing)
    }

    func testErrorEquality() {
        XCTAssertEqual(
            ContinuousListeningState.error("fail"),
            ContinuousListeningState.error("fail")
        )
        XCTAssertNotEqual(
            ContinuousListeningState.error("a"),
            ContinuousListeningState.error("b")
        )
    }
}
