import XCTest
@testable import CodeRelaySpeech

final class VoiceActivityDetectorTests: XCTestCase {

    // 30 ms chunk at 16 kHz = 480 samples.
    private let chunkSize = 480

    private func silenceChunk() -> [Float] {
        Array(repeating: 0.0, count: chunkSize)
    }

    private func speechChunk(amplitude: Float = 0.3) -> [Float] {
        // Non-zero energy — simple constant "speech-like" signal.
        Array(repeating: amplitude, count: chunkSize)
    }

    func testInitialSilenceEmitsSilenceEvents() {
        let vad = VoiceActivityDetector()
        let event = vad.process(chunk: silenceChunk())
        XCTAssertFalse(event.isSpeech)
    }

    func testSpeechChunkAfterSilenceEmitsSpeechStart() {
        let vad = VoiceActivityDetector()
        // Prime with silence first.
        for _ in 0..<5 { _ = vad.process(chunk: silenceChunk()) }

        var sawSpeechStart = false
        for _ in 0..<15 {
            let event = vad.process(chunk: speechChunk())
            if event == .speechStart { sawSpeechStart = true; break }
        }
        XCTAssertTrue(sawSpeechStart, "Expected a speechStart event after sustained speech")
    }

    func testSilenceAfterSpeechEmitsSilenceStart() {
        let vad = VoiceActivityDetector()
        for _ in 0..<15 { _ = vad.process(chunk: speechChunk()) }
        // minSilenceDuration is 1.0s; each chunk is 30ms, so we need 34+ silent
        // chunks before silenceStart can fire. Loop well past that.
        var sawSilenceStart = false
        for _ in 0..<60 {
            let event = vad.process(chunk: silenceChunk())
            if event == .silenceStart { sawSilenceStart = true; break }
        }
        XCTAssertTrue(sawSilenceStart, "Expected a silenceStart event after sustained silence")
    }

    func testBriefSpeechSpikeIsDebounced() {
        let vad = VoiceActivityDetector()
        for _ in 0..<5 { _ = vad.process(chunk: silenceChunk()) }
        // One single speech chunk — below minSpeechDuration, should NOT trip speechStart.
        let event = vad.process(chunk: speechChunk())
        XCTAssertNotEqual(event, .speechStart)
    }

    func testResetClearsState() {
        let vad = VoiceActivityDetector()
        for _ in 0..<15 { _ = vad.process(chunk: speechChunk()) }
        vad.reset()
        // After reset, first silence chunk should emit silenceContinue (no prior speech).
        let event = vad.process(chunk: silenceChunk())
        XCTAssertFalse(event.isSpeech)
        XCTAssertFalse(event.isEdge)
    }
}
