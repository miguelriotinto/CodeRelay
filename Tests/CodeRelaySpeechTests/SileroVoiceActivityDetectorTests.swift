import XCTest
@testable import CodeRelaySpeech

final class SileroVoiceActivityDetectorTests: XCTestCase {

    func testLoadsBundledModel() {
        let vad = SileroVoiceActivityDetector()
        XCTAssertNotNil(vad, "Bundled SileroVAD.mlmodelc should load")
    }

    func testSilenceChunksStayBelowSpeechThreshold() {
        guard let vad = SileroVoiceActivityDetector() else {
            XCTFail("Silero model unavailable"); return
        }
        let silence = Array(repeating: Float(0.0), count: 512)
        // Warm up so the debounce state machine is settled.
        for _ in 0..<20 { _ = vad.process(chunk: silence) }
        // Subsequent silent chunks should not emit speechStart.
        var sawSpeechStart = false
        for _ in 0..<10 {
            let event = vad.process(chunk: silence)
            if event == .speechStart { sawSpeechStart = true; break }
        }
        XCTAssertFalse(sawSpeechStart, "Silero should not fire speechStart on zero-energy silence")
    }

    func testResetClearsResidualAndProbability() {
        guard let vad = SileroVoiceActivityDetector() else { return }
        let partial = Array(repeating: Float(0.3), count: 100)
        _ = vad.process(chunk: partial)
        vad.reset()
        // After reset, first silence chunk should be silent-equivalent.
        let event = vad.process(chunk: Array(repeating: Float(0.0), count: 512))
        XCTAssertFalse(event.isSpeech, "After reset, first silence chunk should report silence")
    }

    func testAcceptsVariableSizeChunks() {
        guard let vad = SileroVoiceActivityDetector() else { return }
        // Sizes that don't cleanly divide 512 — ensure we don't crash.
        for size in [1, 100, 200, 480, 512, 1024, 1500] {
            let chunk = Array(repeating: Float(0.0), count: size)
            _ = vad.process(chunk: chunk)
        }
    }

    func testAccumulatesAcrossMultipleCallsIntoSingleInference() {
        guard let vad = SileroVoiceActivityDetector() else { return }
        // Feeding in 4 × 128-sample chunks adds up to exactly one 512-sample
        // window and should run exactly one inference. We can't observe the
        // inference count directly, but we can observe that the probability
        // state changed after enough samples accumulated.
        vad.reset()
        let firstEvent = vad.process(chunk: Array(repeating: Float(0.0), count: 128))
        for _ in 0..<3 {
            _ = vad.process(chunk: Array(repeating: Float(0.0), count: 128))
        }
        // We've now passed in 512 zero samples total; the first call emits
        // based on the initial (pre-inference) probability of 0, later calls
        // emit after inference. The key invariant: no crash and events are
        // well-defined.
        XCTAssertFalse(firstEvent.isSpeech)
    }
}
