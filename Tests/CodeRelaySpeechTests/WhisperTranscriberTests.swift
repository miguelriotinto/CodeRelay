import XCTest
@testable import CodeRelaySpeech

final class WhisperTranscriberTests: XCTestCase {

    // MARK: - collapseRepetitions: no false positives

    func testNoRepetition() {
        let input = "What is the current working directory?"
        XCTAssertEqual(WhisperTranscriber.collapseRepetitions(input), input)
    }

    func testSingleSentenceNoCollapse() {
        let input = "Please list the files in this project"
        XCTAssertEqual(WhisperTranscriber.collapseRepetitions(input), input)
    }

    func testShortTextUnchanged() {
        XCTAssertEqual(WhisperTranscriber.collapseRepetitions("hi"), "hi")
        XCTAssertEqual(WhisperTranscriber.collapseRepetitions("check the logs"), "check the logs")
    }

    func testLegitimateRepeatedWordsNotCollapsed() {
        let input = "I said go go go and then stopped"
        XCTAssertEqual(WhisperTranscriber.collapseRepetitions(input), input)
    }

    func testTwoDistinctSentencesNotCollapsed() {
        let input = "First run the tests. Then check the coverage."
        XCTAssertEqual(WhisperTranscriber.collapseRepetitions(input), input)
    }

    // MARK: - Sentence-level repetition (punctuation-delimited)

    func testSentenceRepetitionWithQuestionMarks() {
        let input = "What is the current working directory?What is the current working directory?What is the current working directory?"
        XCTAssertEqual(
            WhisperTranscriber.collapseRepetitions(input),
            "What is the current working directory?"
        )
    }

    func testSentenceRepetitionWithSpacesAndPunctuation() {
        let input = "Check the current directory. Check the current directory. Check the current directory."
        XCTAssertEqual(
            WhisperTranscriber.collapseRepetitions(input),
            "Check the current directory."
        )
    }

    func testDoubleRepetitionWithPeriod() {
        let input = "List all files. List all files."
        XCTAssertEqual(
            WhisperTranscriber.collapseRepetitions(input),
            "List all files."
        )
    }

    func testSentenceRepetitionWithMinorVariation() {
        // Whisper sometimes capitalizes differently between loops
        let input = "What time is it? what time is it?"
        XCTAssertEqual(
            WhisperTranscriber.collapseRepetitions(input),
            "What time is it?"
        )
    }

    // MARK: - Character-level repetition (no delimiter)

    func testDirectConcatenationDouble() {
        let input = "check the current directorycheck the current directory"
        XCTAssertEqual(
            WhisperTranscriber.collapseRepetitions(input),
            "check the current directory"
        )
    }

    func testDirectConcatenationTriple() {
        let input = "run the build nowrun the build nowrun the build now"
        XCTAssertEqual(
            WhisperTranscriber.collapseRepetitions(input),
            "run the build now"
        )
    }

    func testRepetitionWithPartialTrailing() {
        let input = "show me the logsshow me the logsshow me the"
        XCTAssertEqual(
            WhisperTranscriber.collapseRepetitions(input),
            "show me the logs"
        )
    }

    // MARK: - Edge cases

    func testExactlyTwentyCharsNotCrash() {
        let input = "12345678901234567890"
        // 20 chars, no repetition — should pass through
        XCTAssertEqual(WhisperTranscriber.collapseRepetitions(input), input)
    }

    func testEmptyAndVeryShort() {
        XCTAssertEqual(WhisperTranscriber.collapseRepetitions(""), "")
        XCTAssertEqual(WhisperTranscriber.collapseRepetitions("a"), "a")
    }
}
