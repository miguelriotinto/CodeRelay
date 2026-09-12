import Foundation
import AVFoundation
import Combine
import os.log
#if canImport(UIKit)
import UIKit
#endif

private let log = Logger(subsystem: "com.coderelay.speech", category: "ContinuousEngine")

/// Orchestrates the continuous listening pipeline in **strict two-phase** mode.
///
/// Phase 1 — wake word:
///   listening (blue) → speechStart → detectingWakeWord (blue)
///     → silenceStart → transcribe → bare "claude"?
///         yes → armed (red)
///         no  → listening (blue)
///
/// Phase 2 — command:
///   armed (red) → speechStart → recording (red)
///     → silenceStart → detectingTurnEnd (red) → turn-end → transcribing (yellow)
///     → cleaning (yellow) → outputting (yellow) → listening (blue)
///
/// If the user says nothing within `armedTimeoutSeconds` of the red signal,
/// the engine snaps back to `.listening`.
///
/// The mic stays open across all states while `enable()`d.
@MainActor
public final class ContinuousListeningEngine: ObservableObject {

    @Published public private(set) var state: ContinuousListeningState = .idle

    /// Called with the final, cleaned utterance text after each turn.
    public var onUtteranceReady: ((String) -> Void)?

    // Pipeline collaborators
    private let vad: any VoiceActivityDetecting
    private var wakeWordDetector: WakeWordDetector
    private let turnEndDetector: any TurnEndDetecting
    private let transcriber: any SpeechTranscribing
    private let postProcessor: SpeechPostProcessor

    // Audio buffer shared across consumers
    private let audioBuffer: StreamingAudioBuffer

    // Utterance tracking (phase 2)
    private var utteranceStartPosition: Int = 0

    /// Pre-roll grabbed when entering `.detectingWakeWord` — covers the VAD
    /// debounce period so the wake word spoken just before `speechStart`
    /// fires still reaches the detector.
    private let wakeWordPreRollSeconds: TimeInterval = 0.5

    /// Max time allowed in `.detectingWakeWord` before we force a check,
    /// in case VAD never transitions back to silence.
    private let wakeWordMaxDuration: TimeInterval = 3.0
    private var wakeWordTimer: Task<Void, Never>?

    /// How long the engine stays in `.armed` waiting for the user to start
    /// their command before timing out back to `.listening`.
    private let armedTimeoutSeconds: TimeInterval = 4.0
    private var armedTimer: Task<Void, Never>?

    /// Current runtime options. Defaults so the engine works unconfigured.
    private var currentOptions: SpeechProcessingOptions = SpeechProcessingOptions()

    /// Task spawned for wake-word check / turn-end check / transcription.
    /// Tracked so tests can await completion and disable() can cancel cleanly.
    private var pendingTask: Task<Void, Never>?

    private let audioSource: any StreamingAudioSourcing
    private var audioStreamContinuation: AsyncStream<[Float]>.Continuation?
    private var audioConsumerTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        vad: any VoiceActivityDetecting,
        wakeWordDetector: WakeWordDetector,
        turnEndDetector: any TurnEndDetecting,
        transcriber: any SpeechTranscribing,
        postProcessor: SpeechPostProcessor,
        audioSource: (any StreamingAudioSourcing)? = nil,
        bufferCapacitySeconds: TimeInterval = 30.0,
        sampleRate: Double = 16000
    ) {
        self.vad = vad
        self.wakeWordDetector = wakeWordDetector
        self.turnEndDetector = turnEndDetector
        self.transcriber = transcriber
        self.postProcessor = postProcessor
        self.audioSource = audioSource ?? StreamingAudioSource()
        self.audioBuffer = StreamingAudioBuffer(
            capacitySeconds: bufferCapacitySeconds,
            sampleRate: sampleRate
        )
        // Drop oldest chunks during processing spikes to keep latency bounded
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(
            bufferingPolicy: .bufferingNewest(10)
        )
        self.audioStreamContinuation = continuation
        self.audioConsumerTask = Task { [weak self] in
            for await samples in stream {
                guard !Task.isCancelled else { break }
                await self?.ingest(chunk: samples)
            }
        }
        self.audioSource.onChunk = { samples in
            continuation.yield(samples)
        }
        self.audioSource.onInterruption = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleInterruption(event)
            }
        }
    }

    // MARK: - Lifecycle

    public func enable() async {
        guard state == .idle else {
            log.debug("enable() called but state is \(String(describing: self.state)) — skipping")
            return
        }

        let whisper = transcriber as? WhisperTranscriber
        if whisper != nil && whisper?.isLoaded != true {
            log.info("Whisper not loaded — loading model before starting...")
            do {
                try await whisper?.loadModel()
                log.info("Whisper model loaded successfully")
            } catch {
                log.error("Whisper model load failed: \(error.localizedDescription)")
                state = .error("Speech model failed to load: \(error.localizedDescription)")
                return
            }
        }

        log.info("VAD: \(String(describing: type(of: self.vad))), TurnEnd: \(String(describing: type(of: self.turnEndDetector))), wake word: '\(self.wakeWordDetector.keyword)'")

        vad.reset()
        wakeWordDetector.reset()
        do {
            try audioSource.start()
            state = .listening
            log.info("✅ Engine enabled — listening for wake word")
        } catch {
            log.error("Audio source failed to start: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    public func disable() async {
        guard state != .idle else { return }
        pendingTask?.cancel()
        pendingTask = nil
        cancelWakeWordTimer()
        cancelArmedTimer()
        audioSource.stop()
        audioStreamContinuation?.finish()
        audioConsumerTask?.cancel()
        audioConsumerTask = nil
        vad.reset()
        wakeWordDetector.reset()
        state = .idle
    }

    // MARK: - Options

    /// Update runtime options. If `wakeWord` changed, rebuilds the
    /// `WakeWordDetector`. Takes effect on the next utterance.
    public func updateOptions(_ new: SpeechProcessingOptions) {
        let wakeWordChanged = new.wakeWord != currentOptions.wakeWord
        currentOptions = new
        if wakeWordChanged {
            wakeWordDetector = WakeWordDetector(
                transcriber: transcriber,
                keyword: new.wakeWord
            )
        }
    }

    // MARK: - Interruption handling

    private func handleInterruption(_ event: StreamingAudioSource.InterruptionEvent) async {
        switch event {
        case .began:
            await disable()
        case .ended(let shouldResume):
            if shouldResume {
                await enable()
            }
        }
    }

    // MARK: - Audio ingestion

    /// Process one audio chunk. In production, called from the audio-engine tap;
    /// in tests, called directly with synthetic samples.
    private var chunkCount: Int = 0
    private var lastLoggedChunkCount: Int = 0

    public func ingest(chunk: [Float]) async {
        guard state != .idle else { return }

        chunkCount += 1
        audioBuffer.append(chunk)

        if chunkCount - lastLoggedChunkCount >= 100 {
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1)))
            log.debug("Audio flowing: chunk #\(self.chunkCount), RMS=\(String(format: "%.5f", rms)), state=\(String(describing: self.state))")
            lastLoggedChunkCount = chunkCount
        }

        let event = vad.process(chunk: chunk)

        if event.isEdge {
            log.info("🎤 VAD edge: \(String(describing: event)) in state=\(String(describing: self.state))")
        }

        switch state {
        case .listening:
            if event == .speechStart {
                wakeWordDetector.reset()
                // Pre-roll captures audio during VAD debounce so the
                // wake word itself isn't cut off.
                let preRoll = audioBuffer.lastSeconds(wakeWordPreRollSeconds)
                if !preRoll.isEmpty {
                    wakeWordDetector.feedAudio(preRoll)
                }
                wakeWordDetector.feedAudio(chunk)
                state = .detectingWakeWord
                log.info("→ .detectingWakeWord (speechStart)")
                startWakeWordTimer()
            }

        case .detectingWakeWord:
            wakeWordDetector.feedAudio(chunk)
            if event == .silenceStart {
                cancelWakeWordTimer()
                log.info("→ silenceStart while detectingWakeWord — running check")
                pendingTask?.cancel()
                runWakeWordCheck()
            }

        case .armed:
            if event == .speechStart {
                cancelArmedTimer()
                utteranceStartPosition = audioBuffer.currentPosition - chunk.count
                state = .recording
                log.info("→ .recording (command speech started)")
            }

        case .recording:
            if event == .silenceStart {
                state = .detectingTurnEnd
                log.info("→ .detectingTurnEnd (silenceStart during recording)")
                runTurnEndCheck()
            }

        case .detectingTurnEnd:
            if event == .speechStart {
                state = .recording
                log.info("→ .recording (speech resumed before turn-end)")
            }

        case .idle, .transcribing, .cleaning, .outputting, .error:
            break
        }
    }

    /// Await any in-flight async work. Public for tests.
    public func waitForPendingWork() async {
        await pendingTask?.value
    }

    // MARK: - Timers

    private func startWakeWordTimer() {
        cancelWakeWordTimer()
        wakeWordTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.wakeWordMaxDuration ?? 3.0))
            guard !Task.isCancelled, let self, self.state == .detectingWakeWord else { return }
            log.info("⏱️ Wake word timer expired — forcing check")
            self.pendingTask?.cancel()
            self.runWakeWordCheck()
        }
    }

    private func cancelWakeWordTimer() {
        wakeWordTimer?.cancel()
        wakeWordTimer = nil
    }

    private func startArmedTimer() {
        cancelArmedTimer()
        armedTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.armedTimeoutSeconds ?? 4.0))
            guard !Task.isCancelled, let self, self.state == .armed else { return }
            log.info("⏱️ Armed timer expired — returning to .listening")
            self.vad.reset()
            self.state = .listening
        }
    }

    private func cancelArmedTimer() {
        armedTimer?.cancel()
        armedTimer = nil
    }

    // MARK: - Pipeline steps

    private func runWakeWordCheck() {
        pendingTask = Task { [weak self] in
            guard let self else { return }
            log.info("🔍 Running wake word check...")
            let result = await self.wakeWordDetector.checkForWakeWord()
            guard !Task.isCancelled else {
                log.debug("Wake word check cancelled")
                return
            }
            self.pendingTask = nil
            self.handleWakeWordResult(result)
        }
    }

    private func handleWakeWordResult(_ result: WakeWordResult) {
        wakeWordDetector.reset()

        switch result {
        case .detected(let residue):
            let trimmedResidue = residue.trimmingCharacters(in: .whitespaces)
            if trimmedResidue.isEmpty {
                // Bare wake word — arm and wait for the command.
                vad.reset()
                state = .armed
                log.info("✅ Wake word DETECTED → .armed (waiting \(self.armedTimeoutSeconds)s for command)")
                startArmedTimer()
            } else {
                // Strict two-phase: reject combined phrases. The user must
                // pause after the wake word so the visual signal can confirm.
                log.info("❌ Wake word matched but with residue '\(trimmedResidue)' — strict two-phase requires pause, discarding")
                vad.reset()
                state = .listening
            }
        case .notDetected:
            log.info("❌ Wake word not detected → .listening")
            vad.reset()
            state = .listening
        case .transcriptionFailed:
            log.error("❌ Wake word transcription failed → .listening")
            vad.reset()
            state = .listening
        }
    }

    private func runTurnEndCheck() {
        let timeoutSeconds = currentOptions.turnEndSilenceTimeout
        pendingTask = Task { [weak self] in
            guard let self else { return }
            let utterance = self.audioBuffer.audioSince(position: self.utteranceStartPosition)

            let decision = await Self.raceTurnEnd(
                detector: self.turnEndDetector,
                utterance: utterance,
                timeoutSeconds: timeoutSeconds
            )
            guard !Task.isCancelled else { return }

            switch decision {
            case .done:
                log.info("Turn-end classifier: speaker DONE — transcribing")
                self.runTranscription(utterance: utterance)
            case .continuing:
                log.info("Turn-end classifier: speaker CONTINUING — back to .recording, awaiting next silence")
                self.state = .recording
            case .inferenceTimedOut:
                // Classifier took longer than the safety-net timeout. Resume
                // recording rather than forcing a chop — the user is almost
                // certainly still speaking or pausing mid-thought. Worst case
                // the next silenceStart fires another check.
                log.warning("⚠️ Turn-end inference exceeded \(timeoutSeconds)s safety net — back to .recording (not forcing transcription)")
                self.state = .recording
            }
        }
    }

    /// Three-way outcome from racing the classifier against a safety-net timer.
    enum TurnEndDecision: Equatable {
        case done
        case continuing
        /// The classifier exceeded the safety-net window. Treat as
        /// "continuing" at the call site — we never want to force-transcribe
        /// on timeout because that re-creates the exact bug where natural
        /// pauses chop the user off.
        case inferenceTimedOut
    }

    /// Race the turn-end classifier against a safety-net timer that guards
    /// against a hung CoreML inference. The timer **never** produces a "done"
    /// verdict — the classifier is authoritative. If the timer wins, we treat
    /// it as `.inferenceTimedOut` and the caller resumes recording.
    static func raceTurnEnd(
        detector: any TurnEndDetecting,
        utterance: [Float],
        timeoutSeconds: TimeInterval
    ) async -> TurnEndDecision {
        await withTaskGroup(of: TurnEndDecision.self) { group in
            group.addTask {
                let r = await detector.predict(utteranceAudio: utterance)
                return r.isDone ? .done : .continuing
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return .inferenceTimedOut
            }
            for await first in group {
                group.cancelAll()
                return first
            }
            return .inferenceTimedOut
        }
    }

    private func runTranscription(utterance: [Float]) {
        let options = currentOptions
        state = .transcribing
        pendingTask = Task { [weak self] in
            guard let self else { return }
            let rawText: String
            do {
                rawText = try await self.transcriber.transcribe(
                    utterance,
                    skipNoSpeechFilter: true
                )
            } catch {
                guard !Task.isCancelled else { return }
                log.info("Transcription empty/failed — back to .listening")
                self.vad.reset()
                self.state = .listening
                return
            }
            guard !Task.isCancelled else { return }
            log.info("Command transcription: '\(rawText)'")

            self.state = .cleaning
            let processed = await self.postProcessor.process(rawText, options: options)
            guard !Task.isCancelled else { return }

            self.state = .outputting
            if let deliverable = processed.deliverableText {
                self.onUtteranceReady?(deliverable)
            }
            self.vad.reset()
            self.state = .listening
        }
    }

    // MARK: - Factory

    /// Production factory: uses Silero VAD + Smart-Turn CoreML detectors when
    /// bundled, falling back to energy-based VAD and heuristic turn-end.
    public static func makeDefault(
        options: SpeechProcessingOptions = SpeechProcessingOptions()
    ) -> ContinuousListeningEngine {
        let vad: any VoiceActivityDetecting
        if let silero = SileroVoiceActivityDetector() {
            vad = silero
            log.info("makeDefault: using SileroVoiceActivityDetector (CoreML)")
        } else {
            vad = VoiceActivityDetector()
            log.info("makeDefault: using energy-based VoiceActivityDetector (fallback)")
        }

        let turnEnd: any TurnEndDetecting
        if let smart = SmartTurnTurnEndDetector() {
            turnEnd = smart
            log.info("makeDefault: using SmartTurnTurnEndDetector (CoreML)")
        } else {
            turnEnd = HeuristicTurnEndDetector()
            log.info("makeDefault: using HeuristicTurnEndDetector (fallback)")
        }

        let transcriber = WhisperTranscriber.shared
        let cleaner = TextCleaner.shared
        let enhancer = CloudPromptEnhancer()
        let wakeWord = WakeWordDetector(transcriber: transcriber, keyword: options.wakeWord)
        let postProcessor = SpeechPostProcessor(cleaner: cleaner, enhancer: enhancer)

        log.info("makeDefault: wakeWord='\(options.wakeWord)'")

        let engine = ContinuousListeningEngine(
            vad: vad,
            wakeWordDetector: wakeWord,
            turnEndDetector: turnEnd,
            transcriber: transcriber,
            postProcessor: postProcessor
        )
        engine.updateOptions(options)
        return engine
    }
}
