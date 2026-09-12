import XCTest
@testable import CodeRelaySpeech

@MainActor
final class SpeechPostProcessorTests: XCTestCase {

    private func makeProcessor(
        cleaner: StubTextCleaner = StubTextCleaner(),
        enhancer: MockCloudEnhancer = MockCloudEnhancer()
    ) -> SpeechPostProcessor {
        SpeechPostProcessor(cleaner: cleaner, enhancer: enhancer)
    }

    func testEmptyInputReturnsEmpty() async {
        let processor = makeProcessor()
        let result = await processor.process("", options: .init())
        XCTAssertEqual(result, .empty)
    }

    func testKnownHallucinationReturnsEmpty() async {
        let processor = makeProcessor()
        let result = await processor.process("Thank you", options: .init())
        XCTAssertEqual(result, .empty)
    }

    func testPassthroughWhenBothFlagsDisabled() async {
        let processor = makeProcessor()
        var opts = SpeechProcessingOptions()
        opts.smartCleanupEnabled = false
        opts.promptEnhancementEnabled = false

        let result = await processor.process("hello world", options: opts)
        XCTAssertEqual(result, .passthrough("hello world"))
    }

    func testCleanupCaseReturnsCleaned() async {
        let cleaner = StubTextCleaner()
        cleaner.result = "cleaned"
        let processor = makeProcessor(cleaner: cleaner)

        let result = await processor.process("um hello", options: .init())
        XCTAssertEqual(result, .cleaned("cleaned"))
        XCTAssertEqual(cleaner.callCount, 1)
    }

    func testCleanupFailureFallsBackToPassthrough() async {
        let cleaner = StubTextCleaner()
        cleaner.shouldThrow = true
        let processor = makeProcessor(cleaner: cleaner)

        let result = await processor.process("um hello", options: .init())
        XCTAssertEqual(result, .passthrough("um hello"))
    }

    func testEnhancementTakesPrecedenceOverCleanup() async {
        let cleaner = StubTextCleaner()
        cleaner.result = "cleaned"
        let enhancer = MockCloudEnhancer()
        enhancer.resultToReturn = "enhanced"
        let processor = makeProcessor(cleaner: cleaner, enhancer: enhancer)

        var opts = SpeechProcessingOptions()
        opts.smartCleanupEnabled = true
        opts.promptEnhancementEnabled = true
        opts.bedrockBearerToken = "token"

        let result = await processor.process("hello world", options: opts)
        XCTAssertEqual(result, .enhanced("enhanced"))
        XCTAssertEqual(cleaner.callCount, 0)
        XCTAssertEqual(enhancer.callCount, 1)
        XCTAssertEqual(enhancer.lastToken, "token")
    }

    func testEnhancementRefusalReturnsRefused() async {
        let enhancer = MockCloudEnhancer()
        enhancer.errorToThrow = EnhancerError.refused
        let processor = makeProcessor(enhancer: enhancer)

        var opts = SpeechProcessingOptions()
        opts.promptEnhancementEnabled = true
        opts.bedrockBearerToken = "token"

        let result = await processor.process("hello world", options: opts)
        XCTAssertEqual(result, .refused(original: "hello world"))
    }

    func testEnhancementOtherErrorFallsBackToCleanup() async {
        let cleaner = StubTextCleaner()
        cleaner.result = "cleaned"
        let enhancer = MockCloudEnhancer()
        enhancer.errorToThrow = URLError(.timedOut)
        let processor = makeProcessor(cleaner: cleaner, enhancer: enhancer)

        var opts = SpeechProcessingOptions()
        opts.smartCleanupEnabled = true
        opts.promptEnhancementEnabled = true
        opts.bedrockBearerToken = "token"

        let result = await processor.process("hello world", options: opts)
        XCTAssertEqual(result, .cleaned("cleaned"))
    }

    func testEmptyTokenSkipsEnhancementAndUsesCleanup() async {
        let cleaner = StubTextCleaner()
        cleaner.result = "cleaned"
        let enhancer = MockCloudEnhancer()
        let processor = makeProcessor(cleaner: cleaner, enhancer: enhancer)

        var opts = SpeechProcessingOptions()
        opts.smartCleanupEnabled = true
        opts.promptEnhancementEnabled = true
        opts.bedrockBearerToken = ""

        let result = await processor.process("hello world", options: opts)
        XCTAssertEqual(result, .cleaned("cleaned"))
        XCTAssertEqual(enhancer.callCount, 0)
    }
}
