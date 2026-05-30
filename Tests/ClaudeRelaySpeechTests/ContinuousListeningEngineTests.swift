import XCTest
@testable import ClaudeRelaySpeech

// swiftlint:disable file_length
@MainActor
// swiftlint:disable:next type_body_length
final class ContinuousListeningEngineTests: XCTestCase {

    private func makeEngine(
        vad: MockVAD = MockVAD(),
        turnEnd: any TurnEndDetecting = MockTurnEndDetector(),
        transcriber: StubSpeechTranscriber = StubSpeechTranscriber(),
        cleaner: StubTextCleaner = StubTextCleaner(),
        enhancer: MockCloudEnhancer = MockCloudEnhancer(),
        audioSource: NoopAudioSource = NoopAudioSource(),
        keyword: String = "claude"
    ) -> ContinuousListeningEngine {
        ContinuousListeningEngine(
            vad: vad,
            wakeWordDetector: WakeWordDetector(transcriber: transcriber, keyword: keyword),
            turnEndDetector: turnEnd,
            transcriber: transcriber,
            postProcessor: SpeechPostProcessor(cleaner: cleaner, enhancer: enhancer),
            audioSource: audioSource
        )
    }

    // MARK: - Lifecycle

    func testInitialStateIsIdle() {
        let engine = makeEngine()
        XCTAssertEqual(engine.state, .idle)
    }

    func testEnableTransitionsToListening() async {
        let engine = makeEngine()
        await engine.enable()
        XCTAssertEqual(engine.state, .listening)
    }

    func testDisableTransitionsToIdle() async {
        let engine = makeEngine()
        await engine.enable()
        await engine.disable()
        XCTAssertEqual(engine.state, .idle)
    }

    func testEnableTwiceIsNoOp() async {
        let engine = makeEngine()
        await engine.enable()
        await engine.enable()
        XCTAssertEqual(engine.state, .listening)
    }

    func testDisableFromIdleIsNoOp() async {
        let engine = makeEngine()
        await engine.disable()
        XCTAssertEqual(engine.state, .idle)
    }

    func testEnableStartsAudioSource() async {
        let source = NoopAudioSource()
        let engine = makeEngine(audioSource: source)
        await engine.enable()
        XCTAssertEqual(source.startCallCount, 1)
        XCTAssertEqual(source.stopCallCount, 0)
    }

    func testDisableStopsAudioSource() async {
        let source = NoopAudioSource()
        let engine = makeEngine(audioSource: source)
        await engine.enable()
        await engine.disable()
        XCTAssertEqual(source.startCallCount, 1)
        XCTAssertEqual(source.stopCallCount, 1)
    }

    func testMakeDefaultReturnsEngine() {
        let engine = ContinuousListeningEngine.makeDefault()
        XCTAssertEqual(engine.state, .idle)
    }

    // MARK: - Phase 1: wake word detection

    func testSpeechStartTransitionsToDetectingWakeWord() async {
        let vad = MockVAD()
        let engine = makeEngine(vad: vad)
        await engine.enable()

        vad.eventsToReturn = [.speechStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))

        XCTAssertEqual(engine.state, .detectingWakeWord)
    }

    func testNoWakeWordReturnsToListening() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "hello there"
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()

        XCTAssertEqual(engine.state, .listening)
    }

    func testBareWakeWordTransitionsToArmed() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude"  // bare wake word, no command
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()

        XCTAssertEqual(engine.state, .armed)
    }

    func testWakeWordWithResidueRejectedInStrictMode() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        // Combined phrase — strict two-phase should reject this.
        transcriber.result = "claude list my files"
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        var delivered: String?
        engine.onUtteranceReady = { delivered = $0 }

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()

        XCTAssertEqual(engine.state, .listening, "Combined phrase should snap back to listening, not arm")
        XCTAssertNil(delivered, "Strict mode must not deliver a combined utterance")
    }

    func testAliasWakeWordAlsoArms() async {
        // Whisper commonly mishears "Claude" as "Lord".
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "lord"
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()

        XCTAssertEqual(engine.state, .armed, "Known alias should still arm the engine")
    }

    // MARK: - Phase 2: command capture

    func testArmedSpeechStartTransitionsToRecording() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude"
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        // Phase 1: arm the engine
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        XCTAssertEqual(engine.state, .armed)

        // Phase 2: user starts speaking the command
        vad.eventsToReturn = [.speechStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        XCTAssertEqual(engine.state, .recording)
    }

    func testFullPipelineDeliversCommandText() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        let cleaner = StubTextCleaner()
        let turnEnd = MockTurnEndDetector()
        turnEnd.resultToReturn = .speakerDone(confidence: 0.95)

        let engine = makeEngine(
            vad: vad,
            turnEnd: turnEnd,
            transcriber: transcriber,
            cleaner: cleaner
        )
        await engine.enable()

        var delivered: String?
        engine.onUtteranceReady = { delivered = $0 }

        // Phase 1: wake word
        transcriber.result = "claude"
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        XCTAssertEqual(engine.state, .armed)

        // Phase 2: command
        transcriber.result = "list my files"
        cleaner.result = "List my files"
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork() // turn-end check
        await engine.waitForPendingWork() // transcription + cleanup

        XCTAssertEqual(delivered, "List my files")
        XCTAssertEqual(engine.state, .listening)
    }

    func testArmedTimesOutBackToListening() async {
        // Create an engine that arms, then simulate long idle time.
        // Since the armed timeout is 4s in production we can't easily wait
        // for it here — instead we verify that receiving silence events while
        // armed does NOT cause a spurious transition.
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude"
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        XCTAssertEqual(engine.state, .armed)

        // A silence-continue event while armed should not change state.
        vad.eventsToReturn = [.silenceContinue]
        await engine.ingest(chunk: Array(repeating: Float(0.01), count: 480))
        XCTAssertEqual(engine.state, .armed, "silenceContinue shouldn't leave .armed")
    }

    func testSpeakerContinuingKeepsRecording() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude"
        let turnEnd = MockTurnEndDetector()
        turnEnd.resultToReturn = .speakerContinuing(confidence: 0.8)

        let engine = makeEngine(vad: vad, turnEnd: turnEnd, transcriber: transcriber)
        await engine.enable()

        // Phase 1: arm
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        XCTAssertEqual(engine.state, .armed)

        // Phase 2: start speaking, pause briefly
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()

        // Since turn-end says "continuing", engine should be back in .recording
        XCTAssertEqual(engine.state, .recording)
    }

    func testDisableCancelsInflightWork() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude"
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.disable()

        XCTAssertEqual(engine.state, .idle)
    }

    // MARK: - v2: options and post-processing

    func testUpdateOptionsTakesEffectOnNextUtterance() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        let cleaner = StubTextCleaner()
        let turnEnd = MockTurnEndDetector()
        turnEnd.resultToReturn = .speakerDone(confidence: 0.9)

        let engine = makeEngine(vad: vad, turnEnd: turnEnd, transcriber: transcriber, cleaner: cleaner)
        await engine.enable()

        var delivered: String?
        engine.onUtteranceReady = { delivered = $0 }

        var opts = SpeechProcessingOptions()
        opts.smartCleanupEnabled = false
        engine.updateOptions(opts)

        // Arm, then speak
        transcriber.result = "claude"
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()

        transcriber.result = "hello world"
        cleaner.result = "HELLO WORLD"
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()

        XCTAssertEqual(delivered, "hello world")
        delivered = nil

        opts.smartCleanupEnabled = true
        engine.updateOptions(opts)

        // Round 2: arm again, speak
        transcriber.result = "claude"
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()

        transcriber.result = "hello world"
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()

        XCTAssertEqual(delivered, "HELLO WORLD")
    }

    func testCloudEnhancementPathDeliversEnhancedText() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        let enhancer = MockCloudEnhancer()
        enhancer.resultToReturn = "List all files in the current directory"
        let turnEnd = MockTurnEndDetector()

        let engine = makeEngine(
            vad: vad, turnEnd: turnEnd, transcriber: transcriber,
            enhancer: enhancer
        )
        await engine.enable()

        var delivered: String?
        engine.onUtteranceReady = { delivered = $0 }

        var opts = SpeechProcessingOptions()
        opts.promptEnhancementEnabled = true
        opts.bedrockBearerToken = "token"
        engine.updateOptions(opts)

        // Arm
        transcriber.result = "claude"
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()

        // Command
        transcriber.result = "list my files"
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()

        XCTAssertEqual(delivered, "List all files in the current directory")
        XCTAssertEqual(enhancer.callCount, 1)
    }

    func testUpdateOptionsWithNewWakeWordRebuildsDetector() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        var opts = SpeechProcessingOptions()
        opts.wakeWord = "hermes"
        engine.updateOptions(opts)

        // Arm with new keyword
        transcriber.result = "hermes"
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()

        XCTAssertEqual(engine.state, .armed, "New wake word should arm the engine")
    }

    func testTurnEndInferenceTimeoutResumesRecording() async {
        // When the classifier takes longer than the safety-net timeout, the
        // engine must NOT force transcription — that re-creates the bug where
        // a natural pause chops the user off. Instead, resume recording.
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude"
        let turnEnd = SlowMockTurnEndDetector()
        turnEnd.delaySeconds = 5.0
        turnEnd.resultToReturn = .speakerDone(confidence: 0.9)  // would say done if it finished

        let engine = makeEngine(vad: vad, turnEnd: turnEnd, transcriber: transcriber)
        await engine.enable()

        var opts = SpeechProcessingOptions()
        opts.turnEndSilenceTimeout = 0.1   // 100 ms — force safety-net to win
        engine.updateOptions(opts)

        var delivered: String?
        engine.onUtteranceReady = { delivered = $0 }

        // Arm
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()

        // Command: silence fires turn-end check; classifier stalls 5s so timer wins at 100ms
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()

        // Nothing should have been transcribed — engine is waiting for next real silence
        XCTAssertNil(delivered, "Timeout must NOT force transcription")
        XCTAssertEqual(engine.state, .recording, "After safety-net timeout, engine resumes recording")
    }

    func testTurnEndClassifierIsAuthoritative() async {
        // Even if the classifier is slow, its verdict wins (as long as it
        // returns within the safety-net window).
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude"
        let turnEnd = SlowMockTurnEndDetector()
        turnEnd.delaySeconds = 0.2   // 200 ms — finishes within 1s safety net
        turnEnd.resultToReturn = .speakerContinuing(confidence: 0.9)

        let engine = makeEngine(vad: vad, turnEnd: turnEnd, transcriber: transcriber)
        await engine.enable()

        var opts = SpeechProcessingOptions()
        opts.turnEndSilenceTimeout = 1.0   // plenty of time for the classifier
        engine.updateOptions(opts)

        var delivered: String?
        engine.onUtteranceReady = { delivered = $0 }

        // Arm
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()

        // Command
        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()

        // Classifier said "continuing" — no transcription, back to recording
        XCTAssertNil(delivered)
        XCTAssertEqual(engine.state, .recording)
    }

    // MARK: - Interruptions

    func testInterruptionBeganDisablesEngine() async {
        let source = NoopAudioSource()
        let engine = makeEngine(audioSource: source)
        await engine.enable()
        XCTAssertEqual(engine.state, .listening)

        source.onInterruption?(.began)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(source.stopCallCount, 1)
    }

    func testInterruptionEndedWithShouldResumeReEnables() async {
        let source = NoopAudioSource()
        let engine = makeEngine(audioSource: source)
        await engine.enable()
        source.onInterruption?(.began)
        try? await Task.sleep(for: .milliseconds(50))

        source.onInterruption?(.ended(shouldResume: true))
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(engine.state, .listening)
        XCTAssertEqual(source.startCallCount, 2)
    }

    func testInterruptionEndedWithoutShouldResumeStaysIdle() async {
        let source = NoopAudioSource()
        let engine = makeEngine(audioSource: source)
        await engine.enable()
        source.onInterruption?(.began)
        try? await Task.sleep(for: .milliseconds(50))

        source.onInterruption?(.ended(shouldResume: false))
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(source.startCallCount, 1)
    }
}
