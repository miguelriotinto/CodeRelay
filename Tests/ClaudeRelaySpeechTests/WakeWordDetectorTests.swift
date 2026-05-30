import XCTest
@testable import ClaudeRelaySpeech

private final class StubTranscriber: SpeechTranscribing {
    var result: String = ""
    var shouldThrow: Bool = false
    var lastSkipNoSpeechFilter: Bool = false

    func transcribe(_ audioBuffer: [Float], skipNoSpeechFilter: Bool) async throws -> String {
        lastSkipNoSpeechFilter = skipNoSpeechFilter
        if shouldThrow { throw TranscriberError.emptyTranscription }
        return result
    }
}

@MainActor
final class WakeWordDetectorTests: XCTestCase {

    // MARK: - Generic wake word detection (any keyword)

    func testExactMatchWithCustomKeyword() async {
        let stub = StubTranscriber()
        stub.result = "jarvis"
        let detector = WakeWordDetector(transcriber: stub, keyword: "jarvis")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .detected(let residue) = result {
            XCTAssertEqual(residue, "")
        } else {
            XCTFail("Expected exact match for custom keyword 'jarvis'")
        }
    }

    func testFuzzyMatchWithCustomKeyword() async {
        let stub = StubTranscriber()
        stub.result = "jarvas"  // 1 edit from 'jarvis'
        let detector = WakeWordDetector(transcriber: stub, keyword: "jarvis")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .detected = result { /* ok */ } else {
            XCTFail("Expected fuzzy match (distance 1) for custom keyword")
        }
    }

    func testNoMatchWithCustomKeyword() async {
        let stub = StubTranscriber()
        stub.result = "hello run diagnostics"
        let detector = WakeWordDetector(transcriber: stub, keyword: "jarvis")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .notDetected = result { /* ok */ } else {
            XCTFail("Expected no match — 'hello' is far from 'jarvis'")
        }
    }

    func testScanWindowLimitsToFirstThreeWords() {
        let result = WakeWordDetector.match(
            transcript: "I was just telling somebody about computer the other day",
            keyword: "computer"
        )
        if case .notDetected = result { /* ok */ } else {
            XCTFail("Keyword beyond first 3 words should not trigger")
        }
    }

    func testKeywordWithinScanWindow() {
        let result = WakeWordDetector.match(
            transcript: "hey computer play some music",
            keyword: "computer"
        )
        if case .detected(let residue) = result {
            XCTAssertEqual(residue, "play some music")
        } else {
            XCTFail("Keyword at word[1] should trigger (within scan window)")
        }
    }

    func testCaseInsensitiveMatchGeneric() {
        let result = WakeWordDetector.match(transcript: "ALEXA", keyword: "alexa")
        if case .detected(let residue) = result {
            XCTAssertEqual(residue, "")
        } else {
            XCTFail("Expected case-insensitive match")
        }
    }

    func testShortWordsSkipped() {
        let result = WakeWordDetector.match(transcript: "oh hi there hello world", keyword: "hello")
        // "oh" (len 2) and "hi" (len 2) are skipped because minLen = keyword.count - 2 = 3
        // "there" at word[2] has distance levenshtein("there", "hello") = 4 > 2
        if case .notDetected = result { /* ok */ } else {
            XCTFail("Expected notDetected when short words are skipped and remaining words don't match")
        }
    }

    func testEmptyTranscriptReturnsNotDetected() {
        let result = WakeWordDetector.match(transcript: "", keyword: "anything")
        XCTAssertEqual(result, .notDetected)
    }

    // MARK: - Levenshtein distance (keyword-agnostic)

    func testLevenshteinExactMatch() {
        XCTAssertEqual(WakeWordDetector.levenshtein("siri", "siri"), 0)
        XCTAssertEqual(WakeWordDetector.levenshtein("computer", "computer"), 0)
    }

    func testLevenshteinOneEdit() {
        XCTAssertEqual(WakeWordDetector.levenshtein("siri", "sir"), 1)
        XCTAssertEqual(WakeWordDetector.levenshtein("alexa", "alex"), 1)
        XCTAssertEqual(WakeWordDetector.levenshtein("claude", "claud"), 1)
    }

    func testLevenshteinTwoEdits() {
        XCTAssertEqual(WakeWordDetector.levenshtein("claude", "cloud"), 2)
        XCTAssertEqual(WakeWordDetector.levenshtein("jarvis", "jarvas"), 1)
        XCTAssertEqual(WakeWordDetector.levenshtein("computer", "compuper"), 1)
    }

    func testLevenshteinEmptyStrings() {
        XCTAssertEqual(WakeWordDetector.levenshtein("", "abc"), 3)
        XCTAssertEqual(WakeWordDetector.levenshtein("abc", ""), 3)
        XCTAssertEqual(WakeWordDetector.levenshtein("", ""), 0)
    }

    // MARK: - No-speech filter bypass

    func testTranscriptionSkipsNoSpeechFilter() async {
        let stub = StubTranscriber()
        stub.result = "relay"
        let detector = WakeWordDetector(transcriber: stub, keyword: "relay")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        _ = await detector.checkForWakeWord()

        XCTAssertTrue(stub.lastSkipNoSpeechFilter, "Wake word check should skip no-speech filter since VAD confirmed speech")
    }

    // MARK: - Phonetic (Metaphone) matching

    func testMetaphonePrimitivesForCommonWords() {
        // "claude" and acoustic neighbors should share a phonetic code.
        XCTAssertEqual(WakeWordDetector.metaphone("claude"), "KLT")
        XCTAssertEqual(WakeWordDetector.metaphone("cloud"), "KLT")
        XCTAssertEqual(WakeWordDetector.metaphone("clod"), "KLT")
        XCTAssertEqual(WakeWordDetector.metaphone("clawed"), "KLT")
    }

    func testMetaphoneKeepsDistinctWordsDistinct() {
        XCTAssertNotEqual(WakeWordDetector.metaphone("claude"), WakeWordDetector.metaphone("hello"))
        XCTAssertNotEqual(WakeWordDetector.metaphone("jarvis"), WakeWordDetector.metaphone("service"))
    }

    func testMetaphoneHandlesEmpty() {
        XCTAssertEqual(WakeWordDetector.metaphone(""), "")
    }

    func testMetaphoneMatchAcceptsPhoneticallySimilarWord() {
        // "clawed" isn't in the alias table for some configurations; phonetic
        // match should still catch it.
        let result = WakeWordDetector.match(transcript: "clod", keyword: "claude")
        if case .detected = result { /* ok */ } else {
            XCTFail("Phonetic match should accept 'clod' as sounding like 'claude'")
        }
    }

    func testMetaphoneMatchRejectsAcousticallyDifferentWord() {
        // "gold" is phonetically quite different from "claude"
        let result = WakeWordDetector.match(transcript: "gold", keyword: "claude")
        if case .notDetected = result { /* ok */ } else {
            XCTFail("Phonetic match should NOT accept 'gold' as similar to 'claude'")
        }
    }

    // MARK: - Known aliases (Claude-specific, but exercising the alias mechanism)

    func testAliasMatchForDefaultKeyword() {
        // "lord" is a known Whisper mishearing of "claude"
        let result = WakeWordDetector.match(transcript: "Lord", keyword: "claude")
        if case .detected(let residue) = result {
            XCTAssertEqual(residue, "")
        } else {
            XCTFail("Expected 'lord' to match as alias of 'claude'")
        }
    }

    func testAliasDoesNotApplyToOtherKeywords() {
        let result = WakeWordDetector.match(transcript: "Lord", keyword: "jarvis")
        if case .notDetected = result { /* ok */ } else {
            XCTFail("Aliases for 'claude' should not match against keyword 'jarvis'")
        }
    }

    // MARK: - Reset and accumulator

    func testResetClearsAudio() async {
        let stub = StubTranscriber()
        stub.result = "computer"
        let detector = WakeWordDetector(transcriber: stub, keyword: "computer")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        detector.reset()

        let result = await detector.checkForWakeWord()
        if case .notDetected = result { /* ok */ } else {
            XCTFail("Expected notDetected after reset (empty accumulator)")
        }
    }

    func testTranscriptionFailureReturnsTranscriptionFailed() async {
        let stub = StubTranscriber()
        stub.shouldThrow = true
        let detector = WakeWordDetector(transcriber: stub, keyword: "anything")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .transcriptionFailed = result { /* ok */ } else {
            XCTFail("Expected transcriptionFailed on thrown error")
        }
    }
}
