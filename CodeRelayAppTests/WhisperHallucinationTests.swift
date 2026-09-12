import XCTest
import CodeRelaySpeech

final class WhisperHallucinationTests: XCTestCase {

    // MARK: - Known hallucinations

    func testThankYouIsHallucination() {
        XCTAssertTrue(TranscriberError.isSilenceHallucination("Thank you"))
    }

    func testThanksForWatchingIsHallucination() {
        XCTAssertTrue(TranscriberError.isSilenceHallucination("Thanks for watching!"))
    }

    func testByeIsHallucination() {
        XCTAssertTrue(TranscriberError.isSilenceHallucination("Bye."))
    }

    func testSubscribeIsHallucination() {
        XCTAssertTrue(TranscriberError.isSilenceHallucination("Subscribe"))
    }

    func testOkayIsHallucination() {
        XCTAssertTrue(TranscriberError.isSilenceHallucination("Okay"))
    }

    func testHmmIsHallucination() {
        XCTAssertTrue(TranscriberError.isSilenceHallucination("Hmm"))
    }

    // MARK: - Case insensitivity & punctuation

    func testCaseInsensitive() {
        XCTAssertTrue(TranscriberError.isSilenceHallucination("THANK YOU"))
        XCTAssertTrue(TranscriberError.isSilenceHallucination("Thank You"))
    }

    func testPunctuationStripped() {
        XCTAssertTrue(TranscriberError.isSilenceHallucination("Thank you!"))
        XCTAssertTrue(TranscriberError.isSilenceHallucination("Bye..."))
        XCTAssertTrue(TranscriberError.isSilenceHallucination("Subscribe!"))
    }

    // MARK: - Normal text is NOT hallucination

    func testNormalTextNotHallucination() {
        XCTAssertFalse(TranscriberError.isSilenceHallucination("Fix the login bug"))
    }

    func testLongerTextNotHallucination() {
        XCTAssertFalse(TranscriberError.isSilenceHallucination("I want to build a feature that lets users subscribe to notifications"))
    }

    func testEmptyStringNotHallucination() {
        XCTAssertFalse(TranscriberError.isSilenceHallucination(""))
    }

    func testWhitespaceOnlyNotHallucination() {
        XCTAssertFalse(TranscriberError.isSilenceHallucination("   "))
    }
}
