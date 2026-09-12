import XCTest
@testable import CodeRelaySpeech

final class SpeechProcessingOptionsTests: XCTestCase {

    func testDefaultsMatchExistingPTTBehavior() {
        let opts = SpeechProcessingOptions()
        XCTAssertTrue(opts.smartCleanupEnabled)
        XCTAssertFalse(opts.promptEnhancementEnabled)
        XCTAssertEqual(opts.bedrockBearerToken, "")
        XCTAssertEqual(opts.bedrockRegion, "us-east-1")
        XCTAssertEqual(opts.wakeWord, "claude")
        XCTAssertEqual(opts.turnEndSilenceTimeout, 8.0, accuracy: 0.001)
    }

    func testEqualityIsValueBased() {
        let a = SpeechProcessingOptions(smartCleanupEnabled: true, wakeWord: "claude")
        let b = SpeechProcessingOptions(smartCleanupEnabled: true, wakeWord: "claude")
        let c = SpeechProcessingOptions(smartCleanupEnabled: true, wakeWord: "hello")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testSendableConformance() {
        let opts = SpeechProcessingOptions()
        Task { _ = opts }
    }
}
