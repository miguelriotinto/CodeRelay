import XCTest
import CodeRelaySpeech
@testable import CodeRelayApp

@MainActor
final class OnDeviceSpeechEngineTests: XCTestCase {

    private var transcriber: MockTranscriber!
    private var cleaner: MockCleaner!

    override func setUp() {
        super.setUp()
        transcriber = MockTranscriber()
        cleaner = MockCleaner()
    }

    func testInitialState() {
        let engine = OnDeviceSpeechEngine(
            transcriber: transcriber,
            cleaner: cleaner,
            capture: AudioCaptureSession(),
            modelStore: .shared
        )
        XCTAssertEqual(engine.state, .idle)
    }

    func testCleanupFallsBackToRawTextOnFailure() async {
        cleaner.shouldThrow = true
        transcriber.resultToReturn = "um hello world"

        let rawText = try? await transcriber.transcribe([])
        XCTAssertEqual(rawText, "um hello world")

        do {
            _ = try await cleaner.clean(rawText!)
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(rawText, "um hello world")
        }
    }

    func testTranscriberCalled() async throws {
        transcriber.resultToReturn = "test output"
        let result = try await transcriber.transcribe([1.0, 2.0, 3.0])
        XCTAssertEqual(result, "test output")
        XCTAssertEqual(transcriber.transcribeCallCount, 1)
    }

    func testCleanerCalled() async throws {
        cleaner.resultToReturn = "cleaned text"
        let result = try await cleaner.clean("dirty text")
        XCTAssertEqual(result, "cleaned text")
        XCTAssertEqual(cleaner.cleanCallCount, 1)
    }
}
