# Continuous Voice Input v2 Implementation Plan

> **Superseded (2026-09-14):** on-device voice transcription was removed from the iOS and macOS apps by `docs/superpowers/specs/2026-09-13-server-prompt-optimizer-design.md`. Kept for history only.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring both push-to-talk and continuous listening engines to feature parity with unified post-processing, ship ML-based turn-end detection via bundled CoreML models (Silero VAD + pipecat Smart-Turn), propagate settings changes dynamically, and harden platform behavior (iOS interruptions, macOS sleep/wake, long-press PTT).

**Architecture:** Extract `SpeechProcessingOptions` (value struct) and `SpeechPostProcessor` (@MainActor class) as the single source of cleanup/enhancement rules. Both engines delegate to the post-processor. Continuous engine gains `updateOptions(_:)` for dynamic settings and a hard-timeout race around Smart-Turn. New CoreML wrappers fall back to v1 baselines when model loading fails. Views wire the mic button's tap/long-press gestures to the new mode-aware UX.

**Tech Stack:** Swift 5.9, CoreML (iOS 17 / macOS 14 stateful models), WhisperKit (existing), AVFoundation, SwiftUI, XCTest. Python + coremltools + torch + silero-vad for one-time model conversion.

---

## File Structure

**New files in `Sources/ClaudeRelaySpeech/`:**
- `SpeechProcessingOptions.swift` — Equatable/Sendable value struct for all runtime options
- `SpeechPostProcessor.swift` — unified cleanup/enhancement entry point
- `ProcessedText.swift` — enum distinguishing passthrough/cleaned/enhanced/refused/empty
- `SileroVoiceActivityDetector.swift` — CoreML-backed VAD
- `SmartTurnTurnEndDetector.swift` — CoreML-backed turn-end classifier
- `Resources/SileroVAD.mlpackage` — bundled model artifact
- `Resources/SmartTurn.mlpackage` — bundled model artifact

**New files in `Tests/ClaudeRelaySpeechTests/`:**
- `SpeechProcessingOptionsTests.swift`
- `SpeechPostProcessorTests.swift`
- `SileroVoiceActivityDetectorTests.swift`
- `SmartTurnTurnEndDetectorTests.swift`
- `MockCloudEnhancer.swift` (reusable stub)

**New files in `tools/speech/`:**
- `convert_silero_vad.py`
- `convert_smart_turn.py`
- `README.md`

**Modified:**
- `Package.swift` — register new resources
- `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift` — accept post-processor, `updateOptions(_:)`, hard timeout, dynamic wake word
- `Sources/ClaudeRelaySpeech/OnDeviceSpeechEngine.swift` — delegate to post-processor with deprecation shim on old signature
- `Sources/ClaudeRelaySpeech/StreamingAudioSource.swift` — AVAudioSession interruption observer, `onInterruption` callback
- `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift` — cover `updateOptions`, hard timeout, enhancement path
- `Tests/ClaudeRelaySpeechTests/MockVADAndDetectors.swift` — `MockCloudEnhancer`, extend `NoopAudioSource` with interruption
- `ClaudeRelayApp/Views/ActiveTerminalView.swift` — options hash, pass options, long-press gesture
- `ClaudeRelayApp/Views/Components/MicButton.swift` — tap-toggles-continuous + long-press PTT UX
- `ClaudeRelayMac/Views/WorkspaceView.swift` — same wire-up on macOS
- `ClaudeRelayMac/Views/MainWindow.swift` — sleep/wake hookup for the engine
- `ClaudeRelayApp/Views/SettingsView.swift`, `ClaudeRelayMac/Views/SettingsView.swift` — footer + tooltip refinements
- `CLAUDE.md` — describe v2 pipeline

---

## Task 1: SpeechProcessingOptions value type

**Files:**
- Create: `Sources/ClaudeRelaySpeech/SpeechProcessingOptions.swift`
- Create: `Tests/ClaudeRelaySpeechTests/SpeechProcessingOptionsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelaySpeechTests/SpeechProcessingOptionsTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

final class SpeechProcessingOptionsTests: XCTestCase {

    func testDefaultsMatchExistingPTTBehavior() {
        let opts = SpeechProcessingOptions()
        XCTAssertTrue(opts.smartCleanupEnabled)
        XCTAssertFalse(opts.promptEnhancementEnabled)
        XCTAssertEqual(opts.bedrockBearerToken, "")
        XCTAssertEqual(opts.bedrockRegion, "us-east-1")
        XCTAssertEqual(opts.wakeWord, "claude")
        XCTAssertEqual(opts.turnEndSilenceTimeout, 1.5, accuracy: 0.001)
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SpeechProcessingOptionsTests`
Expected: FAIL — `SpeechProcessingOptions` not defined.

- [ ] **Step 3: Create the struct**

Create `Sources/ClaudeRelaySpeech/SpeechProcessingOptions.swift`:

```swift
import Foundation

/// All runtime-configurable options that control how a transcript is processed
/// and how the continuous pipeline behaves. Pushed from the UI into both
/// engines; captured at the moment work kicks off so mid-session setting
/// changes take effect on the next utterance.
public struct SpeechProcessingOptions: Equatable, Sendable {
    public var smartCleanupEnabled: Bool
    public var promptEnhancementEnabled: Bool
    public var bedrockBearerToken: String
    public var bedrockRegion: String
    public var wakeWord: String
    public var turnEndSilenceTimeout: TimeInterval

    public init(
        smartCleanupEnabled: Bool = true,
        promptEnhancementEnabled: Bool = false,
        bedrockBearerToken: String = "",
        bedrockRegion: String = "us-east-1",
        wakeWord: String = "claude",
        turnEndSilenceTimeout: TimeInterval = 1.5
    ) {
        self.smartCleanupEnabled = smartCleanupEnabled
        self.promptEnhancementEnabled = promptEnhancementEnabled
        self.bedrockBearerToken = bedrockBearerToken
        self.bedrockRegion = bedrockRegion
        self.wakeWord = wakeWord
        self.turnEndSilenceTimeout = turnEndSilenceTimeout
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter SpeechProcessingOptionsTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/SpeechProcessingOptions.swift Tests/ClaudeRelaySpeechTests/SpeechProcessingOptionsTests.swift
git commit -m "feat(speech): add SpeechProcessingOptions value type"
```

---

## Task 2: ProcessedText enum

**Files:**
- Create: `Sources/ClaudeRelaySpeech/ProcessedText.swift`
- Create: `Tests/ClaudeRelaySpeechTests/ProcessedTextTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelaySpeechTests/ProcessedTextTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

final class ProcessedTextTests: XCTestCase {

    func testDeliverableTextReturnsStringForDeliverableCases() {
        XCTAssertEqual(ProcessedText.passthrough("hi").deliverableText, "hi")
        XCTAssertEqual(ProcessedText.cleaned("clean").deliverableText, "clean")
        XCTAssertEqual(ProcessedText.enhanced("enhanced").deliverableText, "enhanced")
    }

    func testDeliverableTextReturnsNilForRefusedOrEmpty() {
        XCTAssertNil(ProcessedText.refused(original: "hi").deliverableText)
        XCTAssertNil(ProcessedText.empty.deliverableText)
    }

    func testEquatable() {
        XCTAssertEqual(ProcessedText.cleaned("a"), ProcessedText.cleaned("a"))
        XCTAssertNotEqual(ProcessedText.cleaned("a"), ProcessedText.passthrough("a"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ProcessedTextTests`
Expected: FAIL — `ProcessedText` not defined.

- [ ] **Step 3: Create the enum**

Create `Sources/ClaudeRelaySpeech/ProcessedText.swift`:

```swift
import Foundation

/// Result of running a raw transcript through `SpeechPostProcessor`.
/// Callers use `deliverableText` to get the string to send to the terminal,
/// treating `nil` as "emit nothing".
public enum ProcessedText: Equatable, Sendable {
    case passthrough(String)
    case cleaned(String)
    case enhanced(String)
    case refused(original: String)
    case empty

    public var deliverableText: String? {
        switch self {
        case .passthrough(let t), .cleaned(let t), .enhanced(let t): return t
        case .refused, .empty: return nil
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ProcessedTextTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/ProcessedText.swift Tests/ClaudeRelaySpeechTests/ProcessedTextTests.swift
git commit -m "feat(speech): add ProcessedText result enum"
```

---

## Task 3: MockCloudEnhancer test double

**Files:**
- Create: `Tests/ClaudeRelaySpeechTests/MockCloudEnhancer.swift`

> **Context:** The real `CloudPromptEnhancer` lives in `Sources/ClaudeRelaySpeech/CloudPromptEnhancer.swift` as a concrete class. For testability of `SpeechPostProcessor` in Task 4, we introduce a protocol `CloudEnhancing` in Task 4 and have the real enhancer conform. This task pre-creates the mock so Task 4's tests compile.

- [ ] **Step 1: Create the mock stub**

Create `Tests/ClaudeRelaySpeechTests/MockCloudEnhancer.swift`:

```swift
import Foundation
@testable import ClaudeRelaySpeech

/// Test double for cloud prompt enhancement. Returns pre-programmed results
/// or throws a pre-programmed error.
final class MockCloudEnhancer: CloudEnhancing, @unchecked Sendable {
    var resultToReturn: String = "enhanced text"
    var errorToThrow: Error?
    var callCount = 0
    var lastToken: String?
    var lastRegion: String?

    func enhance(_ text: String, bearerToken: String, region: String) async throws -> String {
        callCount += 1
        lastToken = bearerToken
        lastRegion = region
        if let err = errorToThrow { throw err }
        return resultToReturn
    }
}
```

- [ ] **Step 2: Verify the file exists (commit happens with Task 4)**

Run: `ls Tests/ClaudeRelaySpeechTests/MockCloudEnhancer.swift`
Expected: file listed. Don't commit yet — the `CloudEnhancing` protocol is added in Task 4, so the file won't compile alone.

---

## Task 4: SpeechPostProcessor and CloudEnhancing protocol

**Files:**
- Create: `Sources/ClaudeRelaySpeech/SpeechPostProcessor.swift`
- Create: `Tests/ClaudeRelaySpeechTests/SpeechPostProcessorTests.swift`
- Modify: `Sources/ClaudeRelaySpeech/CloudPromptEnhancer.swift` (add protocol conformance)

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeRelaySpeechTests/SpeechPostProcessorTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

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

        let result = await processor.process("hello", options: opts)
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

        let result = await processor.process("hello", options: opts)
        XCTAssertEqual(result, .refused(original: "hello"))
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

        let result = await processor.process("hello", options: opts)
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

        let result = await processor.process("hello", options: opts)
        XCTAssertEqual(result, .cleaned("cleaned"))
        XCTAssertEqual(enhancer.callCount, 0)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SpeechPostProcessorTests`
Expected: FAIL — `SpeechPostProcessor` and `CloudEnhancing` not defined.

- [ ] **Step 3: Add the CloudEnhancing protocol and conformance**

Open `Sources/ClaudeRelaySpeech/CloudPromptEnhancer.swift`. Add this right after `import Foundation`:

```swift
/// Protocol for cloud-based prompt enhancement — enables mock injection.
public protocol CloudEnhancing: Sendable {
    func enhance(_ text: String, bearerToken: String, region: String) async throws -> String
}
```

Find the class declaration `public final class CloudPromptEnhancer {` and change to:

```swift
public final class CloudPromptEnhancer: CloudEnhancing {
```

Do NOT change other logic.

- [ ] **Step 4: Create SpeechPostProcessor**

Create `Sources/ClaudeRelaySpeech/SpeechPostProcessor.swift`:

```swift
import Foundation

/// Unified post-processing for raw Whisper transcripts. Called by both
/// `OnDeviceSpeechEngine` (push-to-talk) and `ContinuousListeningEngine`
/// so `smartCleanupEnabled` / `promptEnhancementEnabled` behave identically
/// across modes.
///
/// Never throws — failures fall back to passthrough or cleanup.
@MainActor
public final class SpeechPostProcessor {

    private let cleaner: any TextCleaning
    private let enhancer: any CloudEnhancing

    public init(cleaner: any TextCleaning, enhancer: any CloudEnhancing) {
        self.cleaner = cleaner
        self.enhancer = enhancer
    }

    public func process(
        _ rawText: String,
        options: SpeechProcessingOptions
    ) async -> ProcessedText {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }

        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount < 2 || TranscriberError.isSilenceHallucination(trimmed) {
            return .empty
        }

        let wantsEnhancement =
            options.promptEnhancementEnabled && !options.bedrockBearerToken.isEmpty

        if wantsEnhancement {
            do {
                let enhanced = try await enhancer.enhance(
                    trimmed,
                    bearerToken: options.bedrockBearerToken,
                    region: options.bedrockRegion
                )
                return .enhanced(enhanced)
            } catch let err as EnhancerError where err == .refused {
                return .refused(original: trimmed)
            } catch {
                if options.smartCleanupEnabled {
                    return await runCleanup(trimmed)
                }
                return .passthrough(trimmed)
            }
        }

        if options.smartCleanupEnabled {
            return await runCleanup(trimmed)
        }
        return .passthrough(trimmed)
    }

    private func runCleanup(_ text: String) async -> ProcessedText {
        do {
            let cleaned = try await cleaner.clean(text)
            return .cleaned(cleaned)
        } catch {
            return .passthrough(text)
        }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter SpeechPostProcessorTests`
Expected: all 9 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelaySpeech/SpeechPostProcessor.swift \
         Sources/ClaudeRelaySpeech/CloudPromptEnhancer.swift \
         Tests/ClaudeRelaySpeechTests/SpeechPostProcessorTests.swift \
         Tests/ClaudeRelaySpeechTests/MockCloudEnhancer.swift
git commit -m "feat(speech): unified SpeechPostProcessor with cleanup plus enhancement"
```

---

## Task 5: Wire SpeechPostProcessor into OnDeviceSpeechEngine

**Files:**
- Modify: `Sources/ClaudeRelaySpeech/OnDeviceSpeechEngine.swift`

- [ ] **Step 1: Change processingTask type**

Open `Sources/ClaudeRelaySpeech/OnDeviceSpeechEngine.swift`. Find the `private var processingTask:` declaration and change its type to:

```swift
    private var processingTask: Task<ProcessedText?, Never>?
```

- [ ] **Step 2: Add the new stopAndProcess(options:) method**

Add this method immediately BEFORE the existing `stopAndProcess(smartCleanup:promptEnhancement:bearerToken:region:)` method:

```swift
    /// Stop recording and process the audio using the unified post-processor.
    /// Returns the string to deliver, or nil if the utterance should produce
    /// no output (silence, refusal, cancellation).
    public func stopAndProcess(options: SpeechProcessingOptions) async -> String? {
        guard state == .recording else { return nil }

        if let existing = processingTask {
            existing.cancel()
            processingTask = nil
        }

        guard let audioBuffer = capture.stop() else {
            state = .idle
            return nil
        }

        let processor = SpeechPostProcessor(cleaner: cleaner, enhancer: cloudEnhancer)
        let engine = self
        let task = Task<ProcessedText?, Never> { [transcriber] in
            let rawText: String
            do {
                rawText = try await transcriber.transcribe(audioBuffer)
            } catch {
                return nil
            }
            guard !Task.isCancelled else { return nil }

            let willProcess = options.smartCleanupEnabled || options.promptEnhancementEnabled
            if willProcess {
                await MainActor.run { engine.state = .cleaning }
            }

            return await processor.process(rawText, options: options)
        }

        processingTask = task
        state = .transcribing

        let result = await task.value
        processingTask = nil

        guard let result else {
            state = .idle
            return nil
        }

        state = .idle
        return result.deliverableText
    }
```

- [ ] **Step 3: Turn old signature into deprecation shim**

Replace the existing `stopAndProcess(smartCleanup:promptEnhancement:bearerToken:region:)` with:

```swift
    @available(*, deprecated, renamed: "stopAndProcess(options:)")
    public func stopAndProcess(
        smartCleanup: Bool = true,
        promptEnhancement: Bool = false,
        bearerToken: String = "",
        region: String = "us-east-1"
    ) async -> String? {
        let options = SpeechProcessingOptions(
            smartCleanupEnabled: smartCleanup,
            promptEnhancementEnabled: promptEnhancement,
            bedrockBearerToken: bearerToken,
            bedrockRegion: region
        )
        return await stopAndProcess(options: options)
    }
```

- [ ] **Step 4: Run existing iOS app tests**

```bash
xcodebuild test \
    -project ClaudeRelay.xcodeproj \
    -scheme ClaudeRelayApp \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
    -only-testing:ClaudeRelayAppTests/OnDeviceSpeechEngineTests \
    2>&1 | tail -20
```

Expected: all existing tests pass via the shim. If a test fails due to deprecation-warning-as-error, update that test to use the new `stopAndProcess(options:)`.

- [ ] **Step 5: Run SPM tests**

Run: `swift test --filter ClaudeRelaySpeechTests`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelaySpeech/OnDeviceSpeechEngine.swift
git commit -m "feat(speech): delegate OnDeviceSpeechEngine processing to SpeechPostProcessor"
```

---

## Task 6: ContinuousListeningEngine updates — updateOptions + SpeechPostProcessor

**Files:**
- Modify: `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`
- Modify: `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift`

- [ ] **Step 1: Add failing tests**

Append to the existing `ContinuousListeningEngineTests` class:

```swift
    // MARK: - v2: options and post-processing

    func testUpdateOptionsTakesEffectOnNextUtterance() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude hello world"
        let cleaner = StubTextCleaner()
        cleaner.result = "HELLO WORLD"
        let turnEnd = MockTurnEndDetector()
        turnEnd.resultToReturn = .speakerDone(confidence: 0.9)

        let engine = makeEngine(vad: vad, turnEnd: turnEnd, transcriber: transcriber, cleaner: cleaner)
        await engine.enable()

        var delivered: String?
        engine.onUtteranceReady = { delivered = $0 }

        var opts = SpeechProcessingOptions()
        opts.smartCleanupEnabled = false
        engine.updateOptions(opts)

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()

        XCTAssertEqual(delivered, "hello world")
        delivered = nil

        opts.smartCleanupEnabled = true
        engine.updateOptions(opts)

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()

        XCTAssertEqual(delivered, "HELLO WORLD")
    }

    func testCloudEnhancementPathDeliversEnhancedText() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude list my files"
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

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()

        XCTAssertEqual(delivered, "List all files in the current directory")
        XCTAssertEqual(enhancer.callCount, 1)
    }

    func testUpdateOptionsWithNewWakeWordRebuildsDetector() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "hermes run diagnostics"
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        var opts = SpeechProcessingOptions()
        opts.wakeWord = "hermes"
        engine.updateOptions(opts)

        var delivered: String?
        engine.onUtteranceReady = { delivered = $0 }

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()

        XCTAssertEqual(delivered, "run diagnostics")
    }
```

Also update the `makeEngine` helper at the top of the test class. Replace with:

```swift
    private func makeEngine(
        vad: MockVAD = MockVAD(),
        turnEnd: MockTurnEndDetector = MockTurnEndDetector(),
        transcriber: StubSpeechTranscriber = StubSpeechTranscriber(),
        cleaner: StubTextCleaner = StubTextCleaner(),
        enhancer: MockCloudEnhancer = MockCloudEnhancer(),
        audioSource: NoopAudioSource = NoopAudioSource()
    ) -> ContinuousListeningEngine {
        ContinuousListeningEngine(
            vad: vad,
            wakeWordDetector: WakeWordDetector(transcriber: transcriber, keyword: "claude"),
            turnEndDetector: turnEnd,
            transcriber: transcriber,
            postProcessor: SpeechPostProcessor(cleaner: cleaner, enhancer: enhancer),
            audioSource: audioSource
        )
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ContinuousListeningEngineTests`
Expected: FAIL — init signature mismatch.

- [ ] **Step 3: Update ContinuousListeningEngine**

Open `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`.

(a) Replace the `cleaner` stored property. Find `private let cleaner: any TextCleaning` and replace with:

```swift
    private let postProcessor: SpeechPostProcessor
```

(b) Add current options storage after `private var wakeWordResidue: String = ""`:

```swift
    /// Current runtime options. Defaults so the engine works unconfigured.
    private var currentOptions: SpeechProcessingOptions = SpeechProcessingOptions()
```

(c) Change `wakeWordDetector` from `let` to `var`:

```swift
    private var wakeWordDetector: WakeWordDetector
```

(d) Replace the init body. Replace the existing `public init(...)` with:

```swift
    public init(
        vad: any VoiceActivityDetecting,
        wakeWordDetector: WakeWordDetector,
        turnEndDetector: any TurnEndDetecting,
        transcriber: any SpeechTranscribing,
        postProcessor: SpeechPostProcessor,
        audioSource: (any StreamingAudioSourcing)? = nil,
        bufferCapacitySeconds: TimeInterval = 10.0,
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
        self.audioSource.onChunk = { [weak self] samples in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.ingest(chunk: samples)
            }
        }
    }
```

(e) Add `updateOptions(_:)` just below `disable()`:

```swift
    // MARK: - Options

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
```

(f) Replace `runTranscription(utterance:)` with:

```swift
    private func runTranscription(utterance: [Float]) {
        let residue = wakeWordResidue
        let options = currentOptions

        state = .transcribing
        pendingTask = Task { [weak self] in
            guard let self else { return }
            let rawText: String
            if !residue.isEmpty {
                rawText = residue
            } else {
                do {
                    rawText = try await self.transcriber.transcribe(utterance)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.state = .listening
                    return
                }
            }
            guard !Task.isCancelled else { return }

            self.state = .cleaning
            let processed = await self.postProcessor.process(rawText, options: options)
            guard !Task.isCancelled else { return }

            self.state = .outputting
            if let deliverable = processed.deliverableText {
                self.onUtteranceReady?(deliverable)
            }
            self.wakeWordResidue = ""
            self.wakeWordDetector.reset()
            self.vad.reset()
            self.state = .listening
        }
    }
```

(g) Update `makeDefault`. Replace with:

```swift
    public static func makeDefault(
        options: SpeechProcessingOptions = SpeechProcessingOptions()
    ) -> ContinuousListeningEngine {
        let vad: any VoiceActivityDetecting = VoiceActivityDetector()
        let turnEnd: any TurnEndDetecting = HeuristicTurnEndDetector()
        let transcriber = WhisperTranscriber.shared
        let cleaner = TextCleaner.shared
        let enhancer = CloudPromptEnhancer()
        let wakeWord = WakeWordDetector(transcriber: transcriber, keyword: options.wakeWord)
        let postProcessor = SpeechPostProcessor(cleaner: cleaner, enhancer: enhancer)

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
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ContinuousListeningEngineTests`
Expected: all engine tests pass (baseline 14 + 3 new = 17).

- [ ] **Step 5: Run the full speech suite**

Run: `swift test --filter ClaudeRelaySpeechTests`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift \
         Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift
git commit -m "feat(speech): ContinuousListeningEngine uses SpeechPostProcessor with updateOptions"
```

---

## Task 7: Hard silence timeout racing Smart-Turn

**Files:**
- Modify: `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`
- Modify: `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift`
- Modify: `Tests/ClaudeRelaySpeechTests/MockVADAndDetectors.swift`

- [ ] **Step 1: Add a slow mock turn-end detector**

Append to `Tests/ClaudeRelaySpeechTests/MockVADAndDetectors.swift`:

```swift
final class SlowMockTurnEndDetector: TurnEndDetecting, @unchecked Sendable {
    var resultToReturn: TurnEndResult = .speakerDone(confidence: 1.0)
    var delaySeconds: TimeInterval = 0.0
    var predictCallCount = 0

    func predict(utteranceAudio: [Float]) async -> TurnEndResult {
        predictCallCount += 1
        if delaySeconds > 0 {
            try? await Task.sleep(for: .seconds(delaySeconds))
        }
        return resultToReturn
    }
}
```

- [ ] **Step 2: Write the failing test**

Append to `ContinuousListeningEngineTests.swift`:

```swift
    func testSmartTurnContinuingKeepsRecordingUntilHardTimeout() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude keep going"
        let turnEnd = SlowMockTurnEndDetector()
        turnEnd.delaySeconds = 5.0
        turnEnd.resultToReturn = .speakerContinuing(confidence: 0.9)

        let engine = makeEngine(vad: vad, turnEnd: turnEnd, transcriber: transcriber)
        await engine.enable()

        var opts = SpeechProcessingOptions()
        opts.turnEndSilenceTimeout = 0.1
        engine.updateOptions(opts)

        var delivered: String?
        engine.onUtteranceReady = { delivered = $0 }

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()

        XCTAssertEqual(delivered, "keep going")
    }
```

Update the `makeEngine` helper signature in the test file to accept a protocol-typed turn-end detector (so both `MockTurnEndDetector` and `SlowMockTurnEndDetector` can be passed):

```swift
    private func makeEngine(
        vad: MockVAD = MockVAD(),
        turnEnd: any TurnEndDetecting = MockTurnEndDetector(),
        transcriber: StubSpeechTranscriber = StubSpeechTranscriber(),
        cleaner: StubTextCleaner = StubTextCleaner(),
        enhancer: MockCloudEnhancer = MockCloudEnhancer(),
        audioSource: NoopAudioSource = NoopAudioSource()
    ) -> ContinuousListeningEngine {
        ContinuousListeningEngine(
            vad: vad,
            wakeWordDetector: WakeWordDetector(transcriber: transcriber, keyword: "claude"),
            turnEndDetector: turnEnd,
            transcriber: transcriber,
            postProcessor: SpeechPostProcessor(cleaner: cleaner, enhancer: enhancer),
            audioSource: audioSource
        )
    }
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter ContinuousListeningEngineTests/testSmartTurnContinuingKeepsRecordingUntilHardTimeout`
Expected: FAIL — the timeout race isn't implemented; test hangs up to 5 s or asserts nil.

- [ ] **Step 3b: Also update tests that referenced MockTurnEndDetector concretely**

The existing tests pass `turnEnd: MockTurnEndDetector` arguments. After changing the parameter type to `any TurnEndDetecting`, those tests should still compile because `MockTurnEndDetector` conforms. Re-run the whole test class after the protocol-type change to confirm.

- [ ] **Step 4: Add the race logic**

Open `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`. Replace `runTurnEndCheck()` with:

```swift
    private func runTurnEndCheck() {
        let timeoutSeconds = currentOptions.turnEndSilenceTimeout
        pendingTask = Task { [weak self] in
            guard let self else { return }
            let utterance = self.audioBuffer.audioSince(position: self.utteranceStartPosition)

            let done = await Self.raceTurnEnd(
                detector: self.turnEndDetector,
                utterance: utterance,
                timeoutSeconds: timeoutSeconds
            )
            guard !Task.isCancelled else { return }
            if done {
                self.runTranscription(utterance: utterance)
            } else {
                self.state = .recording
            }
        }
    }

    /// Race the turn-end classifier against a hard-silence timer.
    /// Timer returning means "force done".
    static func raceTurnEnd(
        detector: any TurnEndDetecting,
        utterance: [Float],
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let r = await detector.predict(utteranceAudio: utterance)
                return r.isDone
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return true
            }
            for await first in group {
                group.cancelAll()
                return first
            }
            return true
        }
    }
```

Delete the now-unused `handleTurnEndResult(_:utterance:)` private method.

- [ ] **Step 5: Run tests**

Run: `swift test --filter ContinuousListeningEngineTests`
Expected: all pass (18 now: 17 baseline + timeout test).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift \
         Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift \
         Tests/ClaudeRelaySpeechTests/MockVADAndDetectors.swift
git commit -m "feat(speech): race Smart-Turn against turnEndSilenceTimeout"
```

---

## Task 8: StreamingAudioSource interruption observer

**Files:**
- Modify: `Sources/ClaudeRelaySpeech/StreamingAudioSource.swift`
- Modify: `Tests/ClaudeRelaySpeechTests/MockVADAndDetectors.swift`
- Create: `Tests/ClaudeRelaySpeechTests/StreamingAudioSourceTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelaySpeechTests/StreamingAudioSourceTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

final class StreamingAudioSourceInterruptionTests: XCTestCase {

    func testInterruptionEventEnumCases() {
        let a = StreamingAudioSource.InterruptionEvent.began
        let b = StreamingAudioSource.InterruptionEvent.ended(shouldResume: true)
        let c = StreamingAudioSource.InterruptionEvent.ended(shouldResume: false)
        XCTAssertNotEqual(String(describing: a), String(describing: b))
        XCTAssertNotEqual(String(describing: b), String(describing: c))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter StreamingAudioSourceInterruptionTests`
Expected: FAIL — `InterruptionEvent` not defined.

- [ ] **Step 3: Extend the protocol and add the event enum**

Open `Sources/ClaudeRelaySpeech/StreamingAudioSource.swift`. Update the protocol to require `onInterruption`:

```swift
public protocol StreamingAudioSourcing: AnyObject, Sendable {
    var onChunk: ((@Sendable ([Float]) -> Void))? { get set }
    var onInterruption: ((@Sendable (StreamingAudioSource.InterruptionEvent) -> Void))? { get set }

    func start() throws
    func stop()
}
```

Inside the `StreamingAudioSource` class (not the protocol), add:

```swift
    public enum InterruptionEvent: Equatable, Sendable {
        case began
        case ended(shouldResume: Bool)
    }

    public var onInterruption: ((@Sendable (InterruptionEvent) -> Void))?
```

Add a stored property for the observer, after `private var isRunning = false`:

```swift
    #if canImport(UIKit)
    private var interruptionObserver: NSObjectProtocol?

    private func handleInterruption(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            onInterruption?(.began)
        case .ended:
            let shouldResume: Bool
            if let optsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
                shouldResume = opts.contains(.shouldResume)
            } else {
                shouldResume = false
            }
            onInterruption?(.ended(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }
    #endif
```

Update `start()` to register the observer (on iOS only). Replace its body with:

```swift
    public func start() throws {
        guard !isRunning else { return }

        #if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
        #endif

        let input = audioEngine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw StreamingAudioSourceError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw StreamingAudioSourceError.converterCreationFailed
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] pcmBuffer, _ in
            guard let self else { return }
            let samples = Self.convert(pcmBuffer, using: converter, targetFormat: targetFormat)
            if !samples.isEmpty {
                self.onChunk?(samples)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
    }
```

Update `stop()` to remove the observer:

```swift
    public func stop() {
        guard isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false

        #if canImport(UIKit)
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        #endif
    }
```

- [ ] **Step 4: Extend NoopAudioSource**

Replace the existing `NoopAudioSource` in `Tests/ClaudeRelaySpeechTests/MockVADAndDetectors.swift` with:

```swift
final class NoopAudioSource: StreamingAudioSourcing, @unchecked Sendable {
    var onChunk: (@Sendable ([Float]) -> Void)?
    var onInterruption: (@Sendable (StreamingAudioSource.InterruptionEvent) -> Void)?
    var startCallCount = 0
    var stopCallCount = 0

    func start() throws { startCallCount += 1 }
    func stop() { stopCallCount += 1 }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter ClaudeRelaySpeechTests`
Expected: all pass including the new compile-check test.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelaySpeech/StreamingAudioSource.swift \
         Tests/ClaudeRelaySpeechTests/MockVADAndDetectors.swift \
         Tests/ClaudeRelaySpeechTests/StreamingAudioSourceTests.swift
git commit -m "feat(speech): expose AVAudioSession interruption events on StreamingAudioSource"
```

---

## Task 9: Engine reacts to interruption events

**Files:**
- Modify: `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`
- Modify: `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `ContinuousListeningEngineTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ContinuousListeningEngineTests`
Expected: 3 new tests fail.

- [ ] **Step 3: Wire the handler**

Open `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`. In `init`, after `self.audioSource.onChunk = ...`, add:

```swift
        self.audioSource.onInterruption = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleInterruption(event)
            }
        }
```

Add the handler at the bottom of the class (before closing brace):

```swift
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
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ContinuousListeningEngineTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift \
         Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift
git commit -m "feat(speech): continuous engine pauses on AVAudioSession interruption"
```

---

## Task 10: Silero VAD CoreML conversion (offline)

> **Context:** Runs a Python script once to produce `SileroVAD.mlpackage`. Artifact is committed to the repo; CI doesn't need Python. If conversion fails for toolchain reasons, mark this task and Task 11 as DEFERRED.

**Files:**
- Create: `tools/speech/convert_silero_vad.py`
- Create: `tools/speech/README.md`
- Create: `Sources/ClaudeRelaySpeech/Resources/SileroVAD.mlpackage` (binary)
- Modify: `Package.swift`

- [ ] **Step 1: Write the conversion script**

Create `tools/speech/convert_silero_vad.py`:

```python
#!/usr/bin/env python3
"""
Convert Silero VAD to CoreML.

Usage:
    pip install torch onnx coremltools silero-vad numpy
    python tools/speech/convert_silero_vad.py

Produces: Sources/ClaudeRelaySpeech/Resources/SileroVAD.mlpackage

The Silero VAD model is recurrent (LSTM-based). We convert with explicit
hidden/cell state tensors as inputs AND outputs, so the Swift wrapper can
thread them between chunks manually.

Input:
    audio: (1, 480) float32
    h: (2, 1, 64) float32
    c: (2, 1, 64) float32

Output:
    prob: (1, 1) float32
    hn:  (2, 1, 64) float32
    cn:  (2, 1, 64) float32
"""
from pathlib import Path

import torch
import coremltools as ct
from silero_vad import load_silero_vad

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = REPO_ROOT / "Sources" / "ClaudeRelaySpeech" / "Resources"
OUT_PATH = OUT_DIR / "SileroVAD.mlpackage"


class SileroVADWrapper(torch.nn.Module):
    def __init__(self, inner):
        super().__init__()
        self.inner = inner

    def forward(self, audio, h, c):
        prob, (hn, cn) = self.inner._model(audio, (h, c), 16000)
        return prob, hn, cn


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    print("[1/3] Loading Silero VAD...")
    inner = load_silero_vad()
    inner.eval()
    wrapper = SileroVADWrapper(inner)
    wrapper.eval()

    example_audio = torch.zeros(1, 480)
    example_h = torch.zeros(2, 1, 64)
    example_c = torch.zeros(2, 1, 64)

    print("[2/3] Tracing...")
    traced = torch.jit.trace(
        wrapper,
        (example_audio, example_h, example_c),
        strict=False,
    )

    print("[3/3] Converting to CoreML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="audio", shape=(1, 480), dtype=ct.models.datatypes.float32),
            ct.TensorType(name="h", shape=(2, 1, 64), dtype=ct.models.datatypes.float32),
            ct.TensorType(name="c", shape=(2, 1, 64), dtype=ct.models.datatypes.float32),
        ],
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.save(str(OUT_PATH))
    print(f"Wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Write the tools README**

Create `tools/speech/README.md`:

```markdown
# Speech Model Conversion Tools

One-time scripts that convert third-party models to CoreML for bundling
with `ClaudeRelaySpeech`. Output artifacts are committed to the repo so
CI doesn't need a Python toolchain.

## Prerequisites

```bash
pip install torch onnx coremltools silero-vad numpy
```

## Silero VAD

```bash
python tools/speech/convert_silero_vad.py
```

Produces `Sources/ClaudeRelaySpeech/Resources/SileroVAD.mlpackage` (~2 MB).

## Smart-Turn

```bash
python tools/speech/convert_smart_turn.py
```

Produces `Sources/ClaudeRelaySpeech/Resources/SmartTurn.mlpackage` (~8 MB).
```

- [ ] **Step 3: Run the conversion**

Run: `python tools/speech/convert_silero_vad.py`
Expected: `SileroVAD.mlpackage` written.

If the script fails (PyTorch/coremltools version mismatch, silero-vad API change, tracer error), STOP and mark Task 10 + Task 11 as DEFERRED.

- [ ] **Step 4: Register the resource**

Open `Package.swift`. Update the `ClaudeRelaySpeech` target to include resources:

```swift
.target(
    name: "ClaudeRelaySpeech",
    dependencies: [
        .product(name: "WhisperKit", package: "WhisperKit"),
        .product(name: "LLM", package: "LLM.swift"),
    ],
    path: "Sources/ClaudeRelaySpeech",
    resources: [
        .copy("Resources/SileroVAD.mlpackage"),
    ]
),
```

- [ ] **Step 5: Verify SPM build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`.

- [ ] **Step 6: Commit**

```bash
git add tools/speech \
         Sources/ClaudeRelaySpeech/Resources/SileroVAD.mlpackage \
         Package.swift
git commit -m "feat(speech): bundle Silero VAD as CoreML resource"
```

---

## Task 11: SileroVoiceActivityDetector

> **Context:** SKIP if Task 10 was deferred.

**Files:**
- Create: `Sources/ClaudeRelaySpeech/SileroVoiceActivityDetector.swift`
- Create: `Tests/ClaudeRelaySpeechTests/SileroVoiceActivityDetectorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelaySpeechTests/SileroVoiceActivityDetectorTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

final class SileroVoiceActivityDetectorTests: XCTestCase {

    func testLoadsBundledModel() {
        let vad = SileroVoiceActivityDetector()
        XCTAssertNotNil(vad, "Bundled SileroVAD.mlpackage should load")
    }

    func testSilenceChunkReturnsLowProbability() {
        guard let vad = SileroVoiceActivityDetector() else {
            XCTFail("model unavailable"); return
        }
        let silence = Array(repeating: Float(0.0), count: 480)
        for _ in 0..<5 { _ = vad.process(chunk: silence) }
        let event = vad.process(chunk: silence)
        XCTAssertFalse(event.isSpeech)
    }

    func testResetDoesNotCrash() {
        guard let vad = SileroVoiceActivityDetector() else { return }
        vad.reset()
    }

    func testRejectsWrongSizeChunk() {
        guard let vad = SileroVoiceActivityDetector() else { return }
        let wrongSize = Array(repeating: Float(0.0), count: 100)
        let event = vad.process(chunk: wrongSize)
        XCTAssertFalse(event.isSpeech)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SileroVoiceActivityDetectorTests`
Expected: FAIL — type not defined.

- [ ] **Step 3: Implement**

Create `Sources/ClaudeRelaySpeech/SileroVoiceActivityDetector.swift`:

```swift
import Foundation
import CoreML

/// CoreML-backed VAD wrapping Silero. Threads LSTM hidden and cell state
/// between 30 ms chunks. Composes with `VoiceActivityDetector`'s hysteresis
/// plus debounce state machine by feeding the model's probability output as
/// the "energy" signal.
public final class SileroVoiceActivityDetector: VoiceActivityDetecting, @unchecked Sendable {

    private let inner: VoiceActivityDetector
    private let model: MLModel

    private var hState: MLMultiArray
    private var cState: MLMultiArray

    public convenience init?(config: VoiceActivityDetector.Config = .init()) {
        guard let url = Bundle.module.url(forResource: "SileroVAD", withExtension: "mlpackage"),
              let loaded = try? MLModel(contentsOf: url),
              let h = try? Self.zeroState(),
              let c = try? Self.zeroState() else {
            return nil
        }
        self.init(model: loaded, hState: h, cState: c, config: config)
    }

    init(model: MLModel, hState: MLMultiArray, cState: MLMultiArray, config: VoiceActivityDetector.Config) {
        self.model = model
        self.hState = hState
        self.cState = cState
        var cfg = config
        cfg.speechThreshold = 0.5
        cfg.silenceThreshold = 0.35
        self.inner = VoiceActivityDetector(config: cfg)
    }

    public func process(chunk: [Float]) -> VADEvent {
        guard chunk.count == 480 else {
            return inner.process(chunk: Array(repeating: 0, count: 480))
        }
        let probability = predict(chunk: chunk)
        return inner.process(chunk: Array(repeating: probability, count: 480))
    }

    public func reset() {
        inner.reset()
        if let h = try? Self.zeroState() { hState = h }
        if let c = try? Self.zeroState() { cState = c }
    }

    // MARK: - Internals

    private static func zeroState() throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: [2, 1, 64], dataType: .float32)
        for i in 0..<arr.count { arr[i] = 0 }
        return arr
    }

    private func predict(chunk: [Float]) -> Float {
        do {
            let audio = try MLMultiArray(shape: [1, 480], dataType: .float32)
            for i in 0..<480 { audio[i] = NSNumber(value: chunk[i]) }

            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "audio": audio,
                "h": hState,
                "c": cState,
            ])
            let output = try model.prediction(from: provider)

            if let hn = output.featureValue(for: "hn")?.multiArrayValue {
                hState = hn
            }
            if let cn = output.featureValue(for: "cn")?.multiArrayValue {
                cState = cn
            }

            if let prob = output.featureValue(for: "prob")?.multiArrayValue,
               prob.count > 0 {
                return Float(truncating: prob[0])
            }
            return 0.0
        } catch {
            return 0.0
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SileroVoiceActivityDetectorTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/SileroVoiceActivityDetector.swift \
         Tests/ClaudeRelaySpeechTests/SileroVoiceActivityDetectorTests.swift
git commit -m "feat(speech): add CoreML-backed SileroVoiceActivityDetector"
```

---

## Task 12: Smart-Turn CoreML conversion and detector

> **Context:** Same deferral policy as Task 10.

**Files:**
- Create: `tools/speech/convert_smart_turn.py`
- Create: `Sources/ClaudeRelaySpeech/Resources/SmartTurn.mlpackage`
- Create: `Sources/ClaudeRelaySpeech/SmartTurnTurnEndDetector.swift`
- Create: `Tests/ClaudeRelaySpeechTests/SmartTurnTurnEndDetectorTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Write the conversion script**

Create `tools/speech/convert_smart_turn.py`:

```python
#!/usr/bin/env python3
"""
Convert pipecat-ai/smart-turn (int8 ONNX) to CoreML.

Usage:
    pip install coremltools onnx
    python tools/speech/convert_smart_turn.py

Downloads the smart-turn int8 ONNX from GitHub releases, converts to
CoreML with static input shape [1, 128000] (8 s @ 16 kHz), writes to
Resources/.
"""
from pathlib import Path
import urllib.request

import coremltools as ct

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = REPO_ROOT / "Sources" / "ClaudeRelaySpeech" / "Resources"
OUT_PATH = OUT_DIR / "SmartTurn.mlpackage"
ONNX_URL = "https://github.com/pipecat-ai/smart-turn/releases/latest/download/smart_turn_int8.onnx"
LOCAL_ONNX = REPO_ROOT / "tools" / "speech" / "smart_turn_int8.onnx"


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    if not LOCAL_ONNX.exists():
        print(f"Downloading {ONNX_URL}...")
        urllib.request.urlretrieve(ONNX_URL, LOCAL_ONNX)

    print("Converting to CoreML...")
    mlmodel = ct.convert(
        str(LOCAL_ONNX),
        inputs=[ct.TensorType(name="audio", shape=(1, 128000), dtype=ct.models.datatypes.float32)],
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.save(str(OUT_PATH))
    print(f"Wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run the conversion**

Run: `python tools/speech/convert_smart_turn.py`
Expected: `SmartTurn.mlpackage` written. If it fails, DEFER this task.

- [ ] **Step 3: Register the resource**

Open `Package.swift`. Extend the resources array:

```swift
resources: [
    .copy("Resources/SileroVAD.mlpackage"),
    .copy("Resources/SmartTurn.mlpackage"),
]
```

- [ ] **Step 4: Write the failing test**

Create `Tests/ClaudeRelaySpeechTests/SmartTurnTurnEndDetectorTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

@MainActor
final class SmartTurnTurnEndDetectorTests: XCTestCase {

    func testModelLoads() {
        let detector = SmartTurnTurnEndDetector()
        XCTAssertNotNil(detector)
    }

    func testPredictReturnsResultForShortAudio() async {
        guard let detector = SmartTurnTurnEndDetector() else { return }
        let audio = Array(repeating: Float(0.0), count: 4000)
        let result = await detector.predict(utteranceAudio: audio)
        switch result {
        case .speakerDone, .speakerContinuing: break
        }
    }

    func testPadOrTruncateHandlesExactSize() {
        let n = 128_000
        let arr = Array(repeating: Float(0.7), count: n)
        let result = SmartTurnTurnEndDetector.padOrTruncate(arr, toCount: n)
        XCTAssertEqual(result.count, n)
        XCTAssertEqual(result.first, 0.7)
    }

    func testPadOrTruncateZeroPadsFromStart() {
        let arr = Array(repeating: Float(0.5), count: 1000)
        let result = SmartTurnTurnEndDetector.padOrTruncate(arr, toCount: 3000)
        XCTAssertEqual(result.count, 3000)
        XCTAssertEqual(result[0], 0.0)
        XCTAssertEqual(result[1999], 0.0)
        XCTAssertEqual(result[2000], 0.5)
        XCTAssertEqual(result[2999], 0.5)
    }

    func testPadOrTruncateTruncatesFromStart() {
        let arr = (0..<1000).map { Float($0) / 1000 }
        let result = SmartTurnTurnEndDetector.padOrTruncate(arr, toCount: 500)
        XCTAssertEqual(result.count, 500)
        XCTAssertEqual(result[0], arr[500])
        XCTAssertEqual(result[499], arr[999])
    }
}
```

- [ ] **Step 5: Run to verify failure**

Run: `swift test --filter SmartTurnTurnEndDetectorTests`
Expected: FAIL — type not defined.

- [ ] **Step 6: Implement**

Create `Sources/ClaudeRelaySpeech/SmartTurnTurnEndDetector.swift`:

```swift
import Foundation
import CoreML

/// CoreML-backed turn-end detector wrapping pipecat-ai/smart-turn.
/// Predicts whether the speaker has finished given up to 8 s of audio.
public final class SmartTurnTurnEndDetector: TurnEndDetecting, @unchecked Sendable {

    private static let requiredSampleCount = 128_000
    private let threshold: Float
    private let model: MLModel

    public convenience init?(threshold: Float = 0.5) {
        guard let url = Bundle.module.url(forResource: "SmartTurn", withExtension: "mlpackage"),
              let loaded = try? MLModel(contentsOf: url) else {
            return nil
        }
        self.init(model: loaded, threshold: threshold)
    }

    init(model: MLModel, threshold: Float) {
        self.model = model
        self.threshold = threshold
    }

    public func predict(utteranceAudio: [Float]) async -> TurnEndResult {
        let padded = Self.padOrTruncate(utteranceAudio, toCount: Self.requiredSampleCount)
        let probability = infer(audio: padded)
        return probability >= threshold
            ? .speakerDone(confidence: probability)
            : .speakerContinuing(confidence: 1.0 - probability)
    }

    static func padOrTruncate(_ samples: [Float], toCount n: Int) -> [Float] {
        if samples.count == n { return samples }
        if samples.count > n { return Array(samples.suffix(n)) }
        var out = Array(repeating: Float(0), count: n - samples.count)
        out.append(contentsOf: samples)
        return out
    }

    private func infer(audio: [Float]) -> Float {
        do {
            let input = try MLMultiArray(shape: [1, NSNumber(value: Self.requiredSampleCount)], dataType: .float32)
            for i in 0..<audio.count {
                input[i] = NSNumber(value: audio[i])
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": input])
            let output = try model.prediction(from: provider)

            if let v = output.featureValue(for: "endpoint_probability")?.multiArrayValue, v.count > 0 {
                return Float(truncating: v[0])
            }
            if let v = output.featureValue(for: "output")?.multiArrayValue, v.count > 0 {
                return Float(truncating: v[0])
            }
            return 1.0
        } catch {
            return 1.0
        }
    }
}
```

- [ ] **Step 7: Run tests**

Run: `swift test --filter SmartTurnTurnEndDetectorTests`
Expected: 5 tests pass.

- [ ] **Step 8: Commit**

```bash
git add tools/speech/convert_smart_turn.py \
         Sources/ClaudeRelaySpeech/Resources/SmartTurn.mlpackage \
         Sources/ClaudeRelaySpeech/SmartTurnTurnEndDetector.swift \
         Tests/ClaudeRelaySpeechTests/SmartTurnTurnEndDetectorTests.swift \
         Package.swift
git commit -m "feat(speech): add Smart-Turn CoreML wrapper"
```

---

## Task 13: makeDefault prefers ML detectors

**Files:**
- Modify: `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`

> SKIP if Tasks 10-12 were deferred (Task 6's factory already uses fallbacks).

- [ ] **Step 1: Update the factory**

Open `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`. Find `makeDefault(options:)` and update the `vad` and `turnEnd` bindings to prefer CoreML:

```swift
    public static func makeDefault(
        options: SpeechProcessingOptions = SpeechProcessingOptions()
    ) -> ContinuousListeningEngine {
        let vad: any VoiceActivityDetecting =
            SileroVoiceActivityDetector() ?? VoiceActivityDetector()
        let turnEnd: any TurnEndDetecting =
            SmartTurnTurnEndDetector() ?? HeuristicTurnEndDetector()
        let transcriber = WhisperTranscriber.shared
        let cleaner = TextCleaner.shared
        let enhancer = CloudPromptEnhancer()
        let wakeWord = WakeWordDetector(transcriber: transcriber, keyword: options.wakeWord)
        let postProcessor = SpeechPostProcessor(cleaner: cleaner, enhancer: enhancer)

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
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter ClaudeRelaySpeechTests`
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift
git commit -m "feat(speech): makeDefault prefers Silero VAD and Smart-Turn"
```

---

## Task 14: iOS MicButton — tap toggle and long-press PTT

**Files:**
- Modify: `ClaudeRelayApp/Views/Components/MicButton.swift`
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift`
- Modify: `ClaudeRelayApp/Models/AppSettings.swift`

- [ ] **Step 1: Add currentSpeechOptions() helper on iOS AppSettings**

Open `ClaudeRelayApp/Models/AppSettings.swift`. At the top, ensure `import ClaudeRelaySpeech` is present. Inside the `AppSettings` class, add:

```swift
    func currentSpeechOptions() -> SpeechProcessingOptions {
        SpeechProcessingOptions(
            smartCleanupEnabled: smartCleanupEnabled,
            promptEnhancementEnabled: promptEnhancementEnabled,
            bedrockBearerToken: bedrockBearerToken,
            bedrockRegion: bedrockRegion,
            wakeWord: wakeWord,
            turnEndSilenceTimeout: turnEndSilenceTimeout
        )
    }
```

- [ ] **Step 2: Rework MicButton**

Open `ClaudeRelayApp/Views/Components/MicButton.swift`. Replace the entire `MicButton` struct with:

```swift
struct MicButton: View {
    @ObservedObject var engine: OnDeviceSpeechEngine
    @ObservedObject var settings: AppSettings
    let coordinator: SessionCoordinator
    @ObservedObject var continuousEngine: ContinuousListeningEngine
    @State private var showDownloadAlert = false
    @State private var continuousPausedByUser = false

    private var activeProgress: Double? {
        engine.modelStore.downloadProgress ?? engine.modelLoadProgress
    }

    var body: some View {
        Button(action: handleTap) {
            label
        }
        .simultaneousGesture(longPressGesture)
        .disabled(isButtonDisabled)
        .alert("Download Speech Models?", isPresented: $showDownloadAlert) {
            Button("Download") {
                Task { await engine.prepareModels() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("On-device voice recognition requires a one-time download (~1 GB). This enables offline, private speech-to-text.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSpeechRecording)) { _ in
            handleTap()
        }
    }

    @ViewBuilder
    private var label: some View {
        Group {
            if let progress = activeProgress {
                ZStack {
                    Circle().stroke(Color.gray.opacity(0.4), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: progress)
                }
                .frame(width: 24, height: 24)
            } else {
                Image(systemName: buttonIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 44, height: 44)
        .background(buttonColor)
        .clipShape(Circle())
        .overlay(alignment: .topTrailing) {
            if settings.continuousListeningEnabled {
                Circle()
                    .fill(continuousDotColor)
                    .frame(width: 10, height: 10)
                    .offset(x: 2, y: -2)
            }
        }
    }

    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .onEnded { _ in
                guard settings.continuousListeningEnabled else { return }
                beginTemporaryPTT()
            }
    }

    private func handleTap() {
        if settings.continuousListeningEnabled {
            handleContinuousTap()
        } else {
            handlePTTTap()
        }
    }

    private func handleContinuousTap() {
        if continuousEngine.state == .idle {
            continuousPausedByUser = false
            Task { await continuousEngine.enable() }
        } else {
            continuousPausedByUser = true
            Task { await continuousEngine.disable() }
        }
        if settings.hapticFeedbackEnabled {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func beginTemporaryPTT() {
        Task {
            await continuousEngine.disable()
            await performOneShotPTT()
            if settings.continuousListeningEnabled && !continuousPausedByUser {
                await continuousEngine.enable()
            }
        }
    }

    private func performOneShotPTT() async {
        if !engine.modelsReady {
            await MainActor.run { showDownloadAlert = true }
            return
        }
        if settings.hapticFeedbackEnabled {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        await engine.startRecording()
        try? await Task.sleep(for: .seconds(2))
        let text = await engine.stopAndProcess(options: settings.currentSpeechOptions())
        if let text, !text.isEmpty {
            guard let id = coordinator.activeSessionId,
                  let vm = coordinator.viewModel(for: id) else { return }
            vm.sendInput(text)
            if settings.hapticFeedbackEnabled {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private func handlePTTTap() {
        switch engine.state {
        case .idle:
            guard engine.modelsReady else {
                showDownloadAlert = true
                return
            }
            if settings.hapticFeedbackEnabled {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            Task { await engine.startRecording() }

        case .recording:
            if settings.hapticFeedbackEnabled {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            Task {
                if let text = await engine.stopAndProcess(options: settings.currentSpeechOptions()) {
                    if settings.hapticFeedbackEnabled {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                    guard let id = coordinator.activeSessionId,
                          let vm = coordinator.viewModel(for: id) else { return }
                    vm.sendInput(text)
                } else {
                    if settings.hapticFeedbackEnabled {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    }
                }
            }

        case .error:
            engine.cancel()

        default:
            break
        }
    }

    private var isButtonDisabled: Bool {
        switch engine.state {
        case .loadingModel, .transcribing, .cleaning:
            return true
        default:
            return activeProgress != nil
        }
    }

    private var buttonIcon: String {
        switch engine.state {
        case .idle, .loadingModel: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .cleaning: return "sparkles"
        case .error: return "mic"
        }
    }

    private var buttonColor: SwiftUI.Color {
        switch engine.state {
        case .idle, .loadingModel: return SwiftUI.Color.gray.opacity(0.5)
        case .recording: return SwiftUI.Color.red.opacity(0.8)
        case .transcribing, .cleaning: return SwiftUI.Color.yellow.opacity(0.8)
        case .error: return SwiftUI.Color.red.opacity(0.8)
        }
    }

    private var continuousDotColor: SwiftUI.Color {
        switch continuousEngine.state {
        case .idle:                 return continuousPausedByUser ? .orange : .gray
        case .listening:            return .green
        case .detectingWakeWord:    return .blue
        case .recording, .detectingTurnEnd: return .red
        case .transcribing, .cleaning:      return .yellow
        case .outputting:           return .green
        case .error:                return .red
        }
    }
}
```

- [ ] **Step 3: Update ActiveTerminalView**

Open `ClaudeRelayApp/Views/ActiveTerminalView.swift`.

Replace the existing `continuousEngine` StateObject with:

```swift
    @StateObject private var continuousEngine = ContinuousListeningEngine.makeDefault(
        options: AppSettings.shared.currentSpeechOptions()
    )
```

Replace the existing `continuousTaskID` property with:

```swift
    private var optionsHash: String {
        let s = settings
        return [
            "\(s.continuousListeningEnabled)",
            "\(s.smartCleanupEnabled)",
            "\(s.promptEnhancementEnabled)",
            s.wakeWord,
            "\(s.turnEndSilenceTimeout)",
            "\(scenePhase)"
        ].joined(separator: "|")
    }
```

Replace the existing `.task(id: continuousTaskID)` modifier with:

```swift
        .task(id: optionsHash) {
            continuousEngine.onUtteranceReady = { text in
                guard let id = coordinator.activeSessionId,
                      let vm = coordinator.viewModel(for: id) else { return }
                vm.sendInput(text)
            }
            continuousEngine.updateOptions(settings.currentSpeechOptions())
            if settings.continuousListeningEnabled && scenePhase == .active {
                await continuousEngine.enable()
            } else {
                await continuousEngine.disable()
            }
        }
```

- [ ] **Step 4: Build**

```bash
xcodebuild build \
    -project ClaudeRelay.xcodeproj \
    -scheme ClaudeRelayApp \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
    2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`. If the named simulator is unavailable, run `xcrun simctl list devices available | grep iPhone` and use an installed one.

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayApp/Views/Components/MicButton.swift \
         ClaudeRelayApp/Views/ActiveTerminalView.swift \
         ClaudeRelayApp/Models/AppSettings.swift
git commit -m "feat(ios): tap toggles continuous, long-press does PTT, options-driven"
```

---

## Task 15: macOS mirror (settings + options + sleep/wake + MacMicButton)

**Files:**
- Modify: `ClaudeRelayMac/Models/AppSettings.swift`
- Modify: `ClaudeRelayMac/Views/WorkspaceView.swift`
- Modify: `ClaudeRelayMac/Views/MainWindow.swift`

- [ ] **Step 1: Add currentSpeechOptions() on Mac AppSettings**

Open `ClaudeRelayMac/Models/AppSettings.swift`. At the top, add (if missing):

```swift
import ClaudeRelaySpeech
```

Inside the class, add:

```swift
    func currentSpeechOptions() -> SpeechProcessingOptions {
        SpeechProcessingOptions(
            smartCleanupEnabled: smartCleanupEnabled,
            promptEnhancementEnabled: promptEnhancementEnabled,
            bedrockBearerToken: bedrockBearerToken,
            bedrockRegion: bedrockRegion,
            wakeWord: wakeWord,
            turnEndSilenceTimeout: turnEndSilenceTimeout
        )
    }
```

- [ ] **Step 2: Update WorkspaceView to push options**

Open `ClaudeRelayMac/Views/WorkspaceView.swift`. Replace the `continuousEngine` StateObject line:

```swift
    @StateObject private var continuousEngine = ContinuousListeningEngine.makeDefault(
        options: AppSettings.shared.currentSpeechOptions()
    )
```

Add an options hash computed property:

```swift
    private var optionsHash: String {
        let s = settings
        return [
            "\(s.continuousListeningEnabled)",
            "\(s.smartCleanupEnabled)",
            "\(s.promptEnhancementEnabled)",
            s.wakeWord,
            "\(s.turnEndSilenceTimeout)"
        ].joined(separator: "|")
    }
```

Replace the existing `.task(id: settings.continuousListeningEnabled)` with:

```swift
        .task(id: optionsHash) {
            continuousEngine.onUtteranceReady = { text in
                guard let id = coordinator.activeSessionId,
                      let vm = coordinator.viewModel(for: id) else { return }
                vm.sendInput(text)
            }
            continuousEngine.updateOptions(settings.currentSpeechOptions())
            if settings.continuousListeningEnabled {
                await continuousEngine.enable()
            } else {
                await continuousEngine.disable()
            }
        }
```

- [ ] **Step 3: Add sleep/wake handling in MainWindow**

Open `ClaudeRelayMac/Views/MainWindow.swift`. If it doesn't already, add `import AppKit` at the top.

Find where the `continuousEngine` is declared — if it's on `MainWindow` AND `WorkspaceView` both have their own, that's a bug. Follow the existing design from Task 18 (v1): the engine lives in WorkspaceView.

Because the engine lives in `WorkspaceView`, sleep/wake needs to either:
- Post a `NotificationCenter` notification that `WorkspaceView` observes, or
- Move the engine up to `MainWindow`

For minimal change, add `NotificationCenter` observation inside `WorkspaceView`. Add these modifiers to the WorkspaceView body (after the existing `.task(id: optionsHash)`):

```swift
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            Task { await continuousEngine.disable() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task {
                if settings.continuousListeningEnabled {
                    await continuousEngine.enable()
                }
            }
        }
```

Ensure `WorkspaceView` imports `AppKit` at the top.

- [ ] **Step 4: Update MacMicButton for tap/long-press**

Open the file where `MacMicButton` is defined (`MainWindow.swift` per v1 Task 18). Replace the `MacMicButton` struct's action handling so that:
1. When `settings.continuousListeningEnabled` is false: tap still does PTT (existing behavior).
2. When true: tap toggles continuous pause/resume; long-press (>= 0.3 s) does a 2-second one-shot PTT.

Replace the `body` of `MacMicButton` following the same pattern as iOS Task 14, Step 2, adapted to the Mac mic button's existing label structure. Specifically, wrap the existing button action with:

```swift
    var body: some View {
        Button(action: handleTap) {
            existingLabelContents   // keep whatever the existing label renders
                .overlay(alignment: .topTrailing) {
                    if settings.continuousListeningEnabled {
                        Circle()
                            .fill(continuousDotColor)
                            .frame(width: 10, height: 10)
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                guard settings.continuousListeningEnabled else { return }
                beginTemporaryPTT()
            }
        )
        // existing .disabled / .alert / etc. modifiers go here
    }

    private func handleTap() {
        if settings.continuousListeningEnabled {
            if continuousEngine.state == .idle {
                Task { await continuousEngine.enable() }
            } else {
                Task { await continuousEngine.disable() }
            }
        } else {
            existingPTTTapLogic()
        }
    }

    private func beginTemporaryPTT() {
        Task {
            await continuousEngine.disable()
            await performOneShotPTT()
            if settings.continuousListeningEnabled {
                await continuousEngine.enable()
            }
        }
    }

    private func performOneShotPTT() async {
        // Reuse existing start/stop recording flow. Key change: call
        // engine.stopAndProcess(options: settings.currentSpeechOptions())
        // instead of the deprecated shim.
    }

    private var continuousDotColor: SwiftUI.Color {
        switch continuousEngine.state {
        case .idle:                 return .gray
        case .listening:            return .green
        case .detectingWakeWord:    return .blue
        case .recording, .detectingTurnEnd: return .red
        case .transcribing, .cleaning:      return .yellow
        case .outputting:           return .green
        case .error:                return .red
        }
    }
```

Replace `existingLabelContents` / `existingPTTTapLogic` with whatever the Mac button currently renders. Preserve hover/pressed styling.

Ensure every call to `engine.stopAndProcess(...)` on this platform uses `options: settings.currentSpeechOptions()`.

- [ ] **Step 5: Build the Mac app**

```bash
xcodebuild build \
    -project ClaudeRelay.xcodeproj \
    -scheme ClaudeRelayMac \
    -destination 'platform=macOS,arch=arm64' \
    2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add ClaudeRelayMac
git commit -m "feat(mac): options-driven continuous engine, sleep/wake, long-press PTT"
```

---

## Task 16: Settings UI polish

**Files:**
- Modify: `ClaudeRelayApp/Views/SettingsView.swift`
- Modify: `ClaudeRelayMac/Views/SettingsView.swift`

- [ ] **Step 1: Refine iOS silence-timeout label and add footer**

Open `ClaudeRelayApp/Views/SettingsView.swift`. Find the existing Silence Timeout row (added in v1 Task 17). Replace:

```swift
                        HStack {
                            Text("Silence Timeout")
                            Spacer()
                            Text("\(settings.turnEndSilenceTimeout, specifier: "%.1f") s")
                                .foregroundStyle(.secondary)
                        }
```

with:

```swift
                        HStack {
                            Text("Silence Timeout")
                                .help("Max time the engine waits for the AI turn-end detector before forcing transcription.")
                            Spacer()
                            Text("\(settings.turnEndSilenceTimeout, specifier: "%.1f") s")
                                .foregroundStyle(.secondary)
                        }
```

After the Slider, before the `}` that closes the `if settings.continuousListeningEnabled` block, add:

```swift
                    Text("Continuous listening uses on-device AI to detect when you've finished speaking.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
```

- [ ] **Step 2: Same for macOS**

Open `ClaudeRelayMac/Views/SettingsView.swift`. Find the Continuous Listening section (added in v1 Task 18). Apply equivalent changes — add `.help(...)` on the Silence Timeout label, and a `Text(...).font(.caption).foregroundStyle(.secondary)` footer row matching the existing Mac section style (use `SettingsSectionFooter` if that helper already exists in this file).

- [ ] **Step 3: Build both**

```bash
xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | tail -3
xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayMac -destination 'platform=macOS,arch=arm64' 2>&1 | tail -3
```

Expected: both `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayApp/Views/SettingsView.swift ClaudeRelayMac/Views/SettingsView.swift
git commit -m "feat(apps): clarify continuous listening settings with help text and footer"
```

---

## Task 17: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Replace the v1 Continuous Listening Pipeline section**

Open `CLAUDE.md`. Find the heading `### Continuous Listening Pipeline`. Replace its body with:

```markdown
### Continuous Listening Pipeline

`ContinuousListeningEngine` is a parallel orchestrator to `OnDeviceSpeechEngine`
powering always-on listening with a wake word ("Claude" by default). Both
engines delegate post-processing (cleanup plus cloud enhancement) to the shared
`SpeechPostProcessor`, so `smartCleanupEnabled` and `promptEnhancementEnabled`
settings behave identically in push-to-talk and continuous modes.

Pipeline:
1. `StreamingAudioSource` (AVAudioEngine tap) -> 30 ms @ 16 kHz mono Float32 chunks
2. `StreamingAudioBuffer` (10 s ring, `OSAllocatedUnfairLock`) — zero-copy append
3. `VoiceActivityDetecting` — `SileroVoiceActivityDetector` (CoreML, LSTM state
   threaded across chunks) when bundled; falls back to energy-based
   `VoiceActivityDetector`
4. On VAD `speechStart` -> `WakeWordDetector` accumulates <= 3 s, runs WhisperKit,
   fuzzy-matches the keyword (Levenshtein <= 1)
5. If matched -> `.detectingTurnEnd`; VAD `silenceStart` during `.recording`
   also routes here
6. `TurnEndDetecting` — `SmartTurnTurnEndDetector` (CoreML, 8 s context,
   zero-padded from start) when bundled; falls back to `HeuristicTurnEndDetector`
7. The classifier is raced against `turnEndSilenceTimeout` so a stuck
   "continuing" prediction can't stall the pipeline
8. On done -> Whisper transcription (skipped when wake-word residue already
   contains the post-wake-word transcript) -> `SpeechPostProcessor.process(...)`
   -> `onUtteranceReady` -> `SessionCoordinator.vm.sendInput(text)`

`ContinuousListeningEngine.makeDefault(options:)` constructs the engine with
the best available detectors. `updateOptions(_:)` pushes settings changes
(incl. wake word, which triggers a `WakeWordDetector` rebuild) without
restarting. iOS responds to `AVAudioSession.interruptionNotification` by
pausing; macOS hooks `NSWorkspace.willSleepNotification` /
`didWakeNotification`.

Push-to-talk (`OnDeviceSpeechEngine`) remains as an alternative mode. When
`continuousListeningEnabled` is on: tap the mic to pause/resume; long-press
for a 2-second one-shot PTT capture without disabling continuous mode.

**Foreground-only:** audio engine starts on `scenePhase == .active` (iOS) or
the Settings toggle (macOS). No background audio entitlement is used.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for continuous voice v2 pipeline"
```

---

## Task 18: Final integration check

- [ ] **Step 1: Run full SPM test suite**

Run: `swift test`
Expected: all ClaudeRelaySpeechTests pass; only pre-existing AuthManagerTests Keychain failures remain.

- [ ] **Step 2: Build both apps**

```bash
xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | tail -3
xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayMac -destination 'platform=macOS,arch=arm64' 2>&1 | tail -3
```

Expected: both `BUILD SUCCEEDED`.

- [ ] **Step 3: Manual verification plan**

With a real mic and the app running, verify:
1. Enable Continuous Listening. Say "Claude, list my files." — text appears without "Claude", locally cleaned.
2. Enable Prompt Enhancement (Bedrock token configured). Say "Claude, list my files." — text is Haiku-rewritten.
3. Change `turnEndSilenceTimeout` to 0.5 s. Say "Claude, ..." — pipeline delivers faster.
4. During continuous mode, phone call on iOS. Engine pauses; after call, engine resumes.
5. Sleep Mac while continuous enabled. Wake. Engine resumes.
6. With continuous ON, tap mic — dot orange (paused). Tap again — dot green. Long-press — ~2 s PTT.
7. Change wake word (internal build) to "hermes" — "hermes" wakes the engine; "claude" no longer does.

Record findings in an empty commit:

```bash
git commit --allow-empty -m "chore(speech): continuous voice v2 verified end-to-end"
```

---

## Self-Review Notes

- Spec §1 (unified post-processing) -> Tasks 1-6
- Spec §2 (ML models) -> Tasks 10-13
- Spec §3 (dynamic settings) -> Task 6 + Tasks 14-15
- Spec §4 (mic UX) -> Tasks 14-15
- Spec §5 (platform robustness) -> Tasks 8-9 (iOS interruption), Task 15 (macOS sleep/wake)
- Spec §6 (test coverage) -> distributed across TDD steps
- Spec §7 (docs + regression) -> Task 17 + deprecation shim in Task 5

Type consistency: `SpeechProcessingOptions(smartCleanupEnabled:promptEnhancementEnabled:bedrockBearerToken:bedrockRegion:wakeWord:turnEndSilenceTimeout:)` signature is identical across all usages. `SpeechPostProcessor.process(_:options:) async -> ProcessedText` is identical in Tasks 4, 5, 6. `ContinuousListeningEngine.updateOptions(_:)` and `makeDefault(options:)` are identical in Tasks 6 and 13.

## Deferred Items

- Hold-while-pressed PTT (current v2 uses a fixed 2-second capture; full hold-to-record needs a custom gesture recognizer).
- User-editable wake-word text field (backend ready; UI is still display-only).
- AWS Bedrock region picker UI.
- iOS background audio entitlement (explicitly out of scope per design).
