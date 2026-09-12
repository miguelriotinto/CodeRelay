import XCTest
import CodeRelaySpeech

final class SpeechEngineStateTests: XCTestCase {

    // MARK: - isActive

    func testIdleIsNotActive() {
        XCTAssertFalse(SpeechEngineState.idle.isActive)
    }

    func testErrorIsNotActive() {
        XCTAssertFalse(SpeechEngineState.error("something").isActive)
    }

    func testLoadingModelIsActive() {
        XCTAssertTrue(SpeechEngineState.loadingModel.isActive)
    }

    func testRecordingIsActive() {
        XCTAssertTrue(SpeechEngineState.recording.isActive)
    }

    func testTranscribingIsActive() {
        XCTAssertTrue(SpeechEngineState.transcribing.isActive)
    }

    func testCleaningIsActive() {
        XCTAssertTrue(SpeechEngineState.cleaning.isActive)
    }

    // MARK: - description

    func testDescriptions() {
        XCTAssertEqual(SpeechEngineState.idle.description, "Idle")
        XCTAssertEqual(SpeechEngineState.loadingModel.description, "Loading model...")
        XCTAssertEqual(SpeechEngineState.recording.description, "Recording...")
        XCTAssertEqual(SpeechEngineState.transcribing.description, "Transcribing...")
        XCTAssertEqual(SpeechEngineState.cleaning.description, "Processing...")
        XCTAssertEqual(SpeechEngineState.error("oops").description, "Error: oops")
    }

    // MARK: - Equatable

    func testEquatable() {
        XCTAssertEqual(SpeechEngineState.idle, SpeechEngineState.idle)
        XCTAssertEqual(SpeechEngineState.error("a"), SpeechEngineState.error("a"))
        XCTAssertNotEqual(SpeechEngineState.error("a"), SpeechEngineState.error("b"))
        XCTAssertNotEqual(SpeechEngineState.idle, SpeechEngineState.recording)
    }
}
