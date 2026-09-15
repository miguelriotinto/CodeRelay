# Continuous Voice Input Implementation Plan

> **Superseded (2026-09-14):** on-device voice transcription was removed from the iOS and macOS apps by `docs/superpowers/specs/2026-09-13-server-prompt-optimizer-design.md`. Kept for history only.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace push-to-talk with always-on microphone listening that wakes on "Claude", records until the speaker finishes (detected via Silero VAD + Smart-Turn classifier), then transcribes → cleans → outputs to the active terminal session.

**Architecture:** Layered pipeline in `ClaudeRelaySpeech`. New `StreamingAudioBuffer` (ring buffer) feeds `VoiceActivityDetector` (Silero VAD, CoreML) on every 30ms chunk. A `ContinuousListeningEngine` orchestrates state transitions: VAD speech → `WakeWordDetector` (short WhisperKit + fuzzy match) → recording → `TurnEndDetector` (VAD silence + Smart-Turn classifier, CoreML) → full transcription → cleanup → output. Runs on both iOS and macOS, foreground-only.

**Tech Stack:** Swift 5.9, WhisperKit (existing), CoreML (Silero VAD + Smart-Turn), AVFoundation, SwiftUI, XCTest. Existing push-to-talk path (`OnDeviceSpeechEngine`) remains untouched.

---

## File Structure

**New files in `Sources/ClaudeRelaySpeech/`:**
- `ContinuousListeningState.swift` — state enum
- `StreamingAudioBuffer.swift` — ring buffer
- `VADEvent.swift` — VAD event enum and protocol
- `VoiceActivityDetector.swift` — Silero VAD wrapper
- `WakeWordDetector.swift` — fuzzy "Claude" matcher
- `TurnEndDetector.swift` — Smart-Turn wrapper (uses `predict` API)
- `ContinuousListeningEngine.swift` — orchestrator
- `Resources/SileroVAD.mlpackage` — bundled model
- `Resources/SmartTurn.mlpackage` — bundled model

**New test target `Tests/ClaudeRelaySpeechTests/`:**
- `StreamingAudioBufferTests.swift`
- `VoiceActivityDetectorTests.swift`
- `WakeWordDetectorTests.swift`
- `TurnEndDetectorTests.swift`
- `ContinuousListeningEngineTests.swift`
- `Fixtures/` — pre-recorded audio samples

**Modified files:**
- `Package.swift` — add `ClaudeRelaySpeechTests` target, add resources to `ClaudeRelaySpeech`
- `ClaudeRelayApp/Models/AppSettings.swift` — new `@AppStorage` keys
- `ClaudeRelayApp/Views/Components/MicButton.swift` — long-press toggle + continuous state
- `ClaudeRelayApp/Views/ActiveTerminalView.swift` — instantiate `ContinuousListeningEngine`
- `ClaudeRelayMac/Views/MainWindow.swift` — same integration on macOS
- `ClaudeRelayApp/Views/SettingsView.swift` — new toggles

---

## Task 0: Set up ClaudeRelaySpeechTests target

**Files:**
- Modify: `Package.swift`
- Create: `Tests/ClaudeRelaySpeechTests/PlaceholderTest.swift`

- [ ] **Step 1: Edit `Package.swift` to add the test target**

Open `Package.swift` and add a new test target after `ClaudeRelayClientTests`:

```swift
.testTarget(
    name: "ClaudeRelaySpeechTests",
    dependencies: ["ClaudeRelaySpeech"],
    path: "Tests/ClaudeRelaySpeechTests",
    resources: [.copy("Fixtures")]
),
```

- [ ] **Step 2: Create the test directory with a placeholder test**

Create `Tests/ClaudeRelaySpeechTests/PlaceholderTest.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

final class PlaceholderTest: XCTestCase {
    func testTargetCompiles() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 3: Create the fixtures directory**

Run: `mkdir -p Tests/ClaudeRelaySpeechTests/Fixtures && touch Tests/ClaudeRelaySpeechTests/Fixtures/.gitkeep`

- [ ] **Step 4: Run the new test target to verify it compiles**

Run: `swift test --filter ClaudeRelaySpeechTests`
Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Tests/ClaudeRelaySpeechTests
git commit -m "test: scaffold ClaudeRelaySpeechTests target"
```

---

## Task 1: ContinuousListeningState enum

**Files:**
- Create: `Sources/ClaudeRelaySpeech/ContinuousListeningState.swift`
- Create: `Tests/ClaudeRelaySpeechTests/ContinuousListeningStateTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelaySpeechTests/ContinuousListeningStateTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

final class ContinuousListeningStateTests: XCTestCase {

    func testIsActiveReturnsFalseForIdle() {
        XCTAssertFalse(ContinuousListeningState.idle.isActive)
    }

    func testIsActiveReturnsTrueForListening() {
        XCTAssertTrue(ContinuousListeningState.listening.isActive)
    }

    func testIsActiveReturnsTrueForRecording() {
        XCTAssertTrue(ContinuousListeningState.recording.isActive)
    }

    func testIsCapturingReturnsTrueForRecording() {
        XCTAssertTrue(ContinuousListeningState.recording.isCapturing)
    }

    func testIsCapturingReturnsTrueForDetectingTurnEnd() {
        XCTAssertTrue(ContinuousListeningState.detectingTurnEnd.isCapturing)
    }

    func testIsCapturingReturnsFalseForListening() {
        XCTAssertFalse(ContinuousListeningState.listening.isCapturing)
    }

    func testErrorEquality() {
        XCTAssertEqual(
            ContinuousListeningState.error("fail"),
            ContinuousListeningState.error("fail")
        )
        XCTAssertNotEqual(
            ContinuousListeningState.error("a"),
            ContinuousListeningState.error("b")
        )
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ContinuousListeningStateTests`
Expected: FAIL — `ContinuousListeningState` is not defined.

- [ ] **Step 3: Create the enum**

Create `Sources/ClaudeRelaySpeech/ContinuousListeningState.swift`:

```swift
import Foundation

/// State machine for the continuous listening pipeline.
/// UI observes this to drive ambient indicators.
public enum ContinuousListeningState: Equatable, Sendable {
    case idle
    case listening              // mic open, waiting for speech
    case detectingWakeWord      // speech heard, checking for "Claude"
    case recording              // wake-word matched, capturing utterance
    case detectingTurnEnd       // checking if speaker is done
    case transcribing           // running WhisperKit on full utterance
    case cleaning               // text cleanup
    case outputting             // delivering to terminal
    case error(String)

    /// True when the engine is doing anything (opposite of idle/error).
    public var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }

    /// True when we are actively accumulating the user's utterance audio.
    public var isCapturing: Bool {
        switch self {
        case .recording, .detectingTurnEnd: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .idle:                 return "Idle"
        case .listening:            return "Listening"
        case .detectingWakeWord:    return "Checking wake word"
        case .recording:            return "Recording"
        case .detectingTurnEnd:     return "Checking turn end"
        case .transcribing:         return "Transcribing"
        case .cleaning:             return "Cleaning"
        case .outputting:           return "Outputting"
        case .error(let msg):       return "Error: \(msg)"
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ContinuousListeningStateTests`
Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/ContinuousListeningState.swift Tests/ClaudeRelaySpeechTests/ContinuousListeningStateTests.swift
git commit -m "feat(speech): add ContinuousListeningState enum"
```

---

## Task 2: StreamingAudioBuffer (ring buffer)

**Files:**
- Create: `Sources/ClaudeRelaySpeech/StreamingAudioBuffer.swift`
- Create: `Tests/ClaudeRelaySpeechTests/StreamingAudioBufferTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeRelaySpeechTests/StreamingAudioBufferTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

final class StreamingAudioBufferTests: XCTestCase {

    func testAppendAndReadLastSecondsWithinCapacity() {
        let buffer = StreamingAudioBuffer(capacitySeconds: 1.0, sampleRate: 16000)
        // 0.5s of samples: 8000 samples at 16kHz
        let samples = Array(repeating: Float(0.5), count: 8000)
        buffer.append(samples)

        let last = buffer.lastSeconds(0.5)
        XCTAssertEqual(last.count, 8000)
        XCTAssertEqual(last.first, 0.5)
        XCTAssertEqual(last.last, 0.5)
    }

    func testLastSecondsReturnsOnlyAvailableAudio() {
        // Request more than was written: return what's there.
        let buffer = StreamingAudioBuffer(capacitySeconds: 5.0, sampleRate: 16000)
        buffer.append(Array(repeating: Float(0.3), count: 4000))  // 0.25s

        let last = buffer.lastSeconds(1.0)
        XCTAssertEqual(last.count, 4000)
    }

    func testOverwritesOldestOnOverflow() {
        let buffer = StreamingAudioBuffer(capacitySeconds: 1.0, sampleRate: 16000)
        // Write 16000 samples of 0.1, then 16000 samples of 0.9.
        // Capacity is 16000, so after second write only 0.9 should remain.
        buffer.append(Array(repeating: Float(0.1), count: 16000))
        buffer.append(Array(repeating: Float(0.9), count: 16000))

        let last = buffer.lastSeconds(1.0)
        XCTAssertEqual(last.count, 16000)
        XCTAssertEqual(last.first, 0.9)
        XCTAssertEqual(last.last, 0.9)
    }

    func testPartialOverwriteKeepsNewest() {
        let buffer = StreamingAudioBuffer(capacitySeconds: 1.0, sampleRate: 16000)
        // 16000 sample capacity.
        buffer.append(Array(repeating: Float(0.1), count: 10000))
        buffer.append(Array(repeating: Float(0.9), count: 10000))

        // Total writes: 20000, capacity 16000, so last 16000 = 6000 of 0.1 + 10000 of 0.9
        let last = buffer.lastSeconds(1.0)
        XCTAssertEqual(last.count, 16000)
        XCTAssertEqual(last[0], 0.1)
        XCTAssertEqual(last[5999], 0.1)
        XCTAssertEqual(last[6000], 0.9)
        XCTAssertEqual(last[15999], 0.9)
    }

    func testAudioSincePosition() {
        let buffer = StreamingAudioBuffer(capacitySeconds: 5.0, sampleRate: 16000)
        let markA = buffer.currentPosition

        buffer.append(Array(repeating: Float(0.2), count: 5000))
        let markB = buffer.currentPosition

        buffer.append(Array(repeating: Float(0.7), count: 5000))

        let since = buffer.audioSince(position: markB)
        XCTAssertEqual(since.count, 5000)
        XCTAssertEqual(since.first, 0.7)

        let sinceA = buffer.audioSince(position: markA)
        XCTAssertEqual(sinceA.count, 10000)
        XCTAssertEqual(sinceA.first, 0.2)
        XCTAssertEqual(sinceA.last, 0.7)
    }

    func testAudioSinceReturnsEmptyWhenPositionLost() {
        // Position older than buffer capacity — return at most capacity, don't crash.
        let buffer = StreamingAudioBuffer(capacitySeconds: 1.0, sampleRate: 16000)
        let stalePosition = buffer.currentPosition

        buffer.append(Array(repeating: Float(0.1), count: 32000))  // overwrites capacity twice

        let since = buffer.audioSince(position: stalePosition)
        XCTAssertLessThanOrEqual(since.count, 16000)
    }

    func testConcurrentAppendsAreSerialized() {
        let buffer = StreamingAudioBuffer(capacitySeconds: 10.0, sampleRate: 16000)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.append", attributes: .concurrent)

        for i in 0..<10 {
            group.enter()
            queue.async {
                let chunk = Array(repeating: Float(i) * 0.1, count: 1000)
                buffer.append(chunk)
                group.leave()
            }
        }

        group.wait()
        let total = buffer.lastSeconds(10.0)
        XCTAssertEqual(total.count, 10 * 1000)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter StreamingAudioBufferTests`
Expected: FAIL — `StreamingAudioBuffer` not defined.

- [ ] **Step 3: Implement the ring buffer**

Create `Sources/ClaudeRelaySpeech/StreamingAudioBuffer.swift`:

```swift
import Foundation
import os.lock

/// Thread-safe ring buffer for streaming 16 kHz mono audio.
///
/// Fixed capacity — oldest samples are overwritten on overflow. Appends
/// are safe from the audio thread; reads return independent copies so
/// async consumers (Whisper, Smart-Turn) can process without a lock.
public final class StreamingAudioBuffer: @unchecked Sendable {

    private var storage: [Float]
    private let capacity: Int
    private let sampleRate: Double

    /// Monotonic sample-count since buffer creation. Callers mark
    /// positions to extract slices later via `audioSince(position:)`.
    private var writeCount: Int = 0

    private var lock = os_unfair_lock_s()

    public init(capacitySeconds: TimeInterval, sampleRate: Double) {
        let cap = Int(capacitySeconds * sampleRate)
        self.capacity = cap
        self.sampleRate = sampleRate
        self.storage = Array(repeating: 0, count: cap)
    }

    /// Current monotonic write position. Use as a marker before
    /// calling `audioSince(position:)` to extract an utterance.
    public var currentPosition: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return writeCount
    }

    /// Append samples from the audio thread. Wraps around on overflow.
    public func append(_ samples: [Float]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        for sample in samples {
            storage[writeCount % capacity] = sample
            writeCount += 1
        }
    }

    /// Read the most recent `duration` seconds of audio. If fewer samples are
    /// available, returns what's there. Returns an independent copy.
    public func lastSeconds(_ duration: TimeInterval) -> [Float] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let wanted = min(Int(duration * sampleRate), writeCount, capacity)
        if wanted == 0 { return [] }

        let startAbsolute = writeCount - wanted
        return extractSlice(fromAbsolute: startAbsolute, count: wanted)
    }

    /// Read audio written since the given position. If that position has
    /// been overwritten (older than capacity), returns the oldest available
    /// samples up to capacity.
    public func audioSince(position: Int) -> [Float] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let oldestAvailable = max(0, writeCount - capacity)
        let startAbsolute = max(position, oldestAvailable)
        let count = writeCount - startAbsolute
        if count <= 0 { return [] }

        return extractSlice(fromAbsolute: startAbsolute, count: count)
    }

    /// Must be called with the lock held.
    private func extractSlice(fromAbsolute start: Int, count: Int) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(storage[(start + i) % capacity])
        }
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter StreamingAudioBufferTests`
Expected: All 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/StreamingAudioBuffer.swift Tests/ClaudeRelaySpeechTests/StreamingAudioBufferTests.swift
git commit -m "feat(speech): add StreamingAudioBuffer ring buffer"
```

---

## Task 3: VADEvent enum and VoiceActivityDetecting protocol

**Files:**
- Create: `Sources/ClaudeRelaySpeech/VADEvent.swift`
- Create: `Tests/ClaudeRelaySpeechTests/VADEventTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelaySpeechTests/VADEventTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

final class VADEventTests: XCTestCase {

    func testIsSpeechTrueForSpeechEvents() {
        XCTAssertTrue(VADEvent.speechStart.isSpeech)
        XCTAssertTrue(VADEvent.speechContinue.isSpeech)
    }

    func testIsSpeechFalseForSilenceEvents() {
        XCTAssertFalse(VADEvent.silenceStart.isSpeech)
        XCTAssertFalse(VADEvent.silenceContinue.isSpeech)
    }

    func testIsEdgeTrueForStartEvents() {
        XCTAssertTrue(VADEvent.speechStart.isEdge)
        XCTAssertTrue(VADEvent.silenceStart.isEdge)
    }

    func testIsEdgeFalseForContinueEvents() {
        XCTAssertFalse(VADEvent.speechContinue.isEdge)
        XCTAssertFalse(VADEvent.silenceContinue.isEdge)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter VADEventTests`
Expected: FAIL — `VADEvent` not defined.

- [ ] **Step 3: Create the event enum and protocol**

Create `Sources/ClaudeRelaySpeech/VADEvent.swift`:

```swift
import Foundation

/// Events emitted by a voice activity detector per audio chunk.
public enum VADEvent: Equatable, Sendable {
    case speechStart         // first chunk of a speech segment
    case speechContinue      // subsequent speech chunk
    case silenceStart        // first chunk of silence after speech
    case silenceContinue     // ongoing silence

    public var isSpeech: Bool {
        switch self {
        case .speechStart, .speechContinue: return true
        case .silenceStart, .silenceContinue: return false
        }
    }

    /// True for start-of-segment events; callers usually only act on these.
    public var isEdge: Bool {
        switch self {
        case .speechStart, .silenceStart: return true
        case .speechContinue, .silenceContinue: return false
        }
    }
}

/// Protocol for voice activity detection — enables mock injection in tests.
public protocol VoiceActivityDetecting: AnyObject, Sendable {
    /// Process one audio chunk and return the resulting event.
    func process(chunk: [Float]) -> VADEvent

    /// Reset internal state (e.g., recurrent hidden state, debounce counters).
    func reset()
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter VADEventTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/VADEvent.swift Tests/ClaudeRelaySpeechTests/VADEventTests.swift
git commit -m "feat(speech): add VADEvent enum and VoiceActivityDetecting protocol"
```

---

## Task 4: VoiceActivityDetector (energy-based baseline)

> **Context:** The real Silero VAD needs a CoreML-converted model file (covered in Task 12). To unblock downstream components, we first ship an **energy-based VAD** that implements the protocol. It's good enough for wire-up tests and stays as a fallback when the CoreML model isn't available.

**Files:**
- Create: `Sources/ClaudeRelaySpeech/VoiceActivityDetector.swift`
- Create: `Tests/ClaudeRelaySpeechTests/VoiceActivityDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeRelaySpeechTests/VoiceActivityDetectorTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

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
        var sawSilenceStart = false
        for _ in 0..<20 {
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter VoiceActivityDetectorTests`
Expected: FAIL — `VoiceActivityDetector` not defined.

- [ ] **Step 3: Implement the energy-based VAD**

Create `Sources/ClaudeRelaySpeech/VoiceActivityDetector.swift`:

```swift
import Foundation

/// Energy-based voice activity detector with hysteresis and debouncing.
///
/// Baseline implementation using RMS energy as the speech/silence signal —
/// simple and dependency-free. The CoreML-backed `SileroVoiceActivityDetector`
/// can substitute its probability output for the energy score while reusing
/// the same state machine.
///
/// Processes 30 ms chunks (480 samples at 16 kHz).
public final class VoiceActivityDetector: VoiceActivityDetecting, @unchecked Sendable {

    public struct Config {
        /// RMS energy above this = speech.
        public var speechThreshold: Float = 0.015
        /// RMS energy below this = silence. Between thresholds = hysteresis hold.
        public var silenceThreshold: Float = 0.008
        /// Chunk duration — fixed to 30 ms at 16 kHz.
        public var chunkDurationSeconds: TimeInterval = 0.030
        /// Minimum sustained speech before emitting speechStart.
        public var minSpeechDuration: TimeInterval = 0.25
        /// Minimum sustained silence before emitting silenceStart.
        public var minSilenceDuration: TimeInterval = 0.30

        public init() {}
    }

    public enum InternalState { case silent, speaking }

    public let config: Config
    private var state: InternalState = .silent

    private var pendingSpeechChunks: Int = 0
    private var pendingSilenceChunks: Int = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    public func process(chunk: [Float]) -> VADEvent {
        let energy = Self.rms(chunk)
        let signal: Bool = Self.scoreToBool(
            energy: energy,
            state: state,
            speechThreshold: config.speechThreshold,
            silenceThreshold: config.silenceThreshold
        )
        return transition(signalIsSpeech: signal)
    }

    public func reset() {
        state = .silent
        pendingSpeechChunks = 0
        pendingSilenceChunks = 0
    }

    // MARK: - Internals

    /// Root-mean-square of a chunk. Allocation-free.
    static func rms(_ chunk: [Float]) -> Float {
        if chunk.isEmpty { return 0 }
        var sumSquares: Float = 0
        for sample in chunk {
            sumSquares += sample * sample
        }
        return (sumSquares / Float(chunk.count)).squareRoot()
    }

    /// Hysteresis-aware speech/silence decision.
    static func scoreToBool(
        energy: Float,
        state: InternalState,
        speechThreshold: Float,
        silenceThreshold: Float
    ) -> Bool {
        switch state {
        case .silent:  return energy >= speechThreshold
        case .speaking: return energy >= silenceThreshold
        }
    }

    private func transition(signalIsSpeech: Bool) -> VADEvent {
        let minSpeechChunks = chunks(for: config.minSpeechDuration)
        let minSilenceChunks = chunks(for: config.minSilenceDuration)

        switch state {
        case .silent:
            if signalIsSpeech {
                pendingSpeechChunks += 1
                if pendingSpeechChunks >= minSpeechChunks {
                    state = .speaking
                    pendingSpeechChunks = 0
                    pendingSilenceChunks = 0
                    return .speechStart
                }
                return .silenceContinue  // still silent (debouncing)
            } else {
                pendingSpeechChunks = 0
                return .silenceContinue
            }

        case .speaking:
            if signalIsSpeech {
                pendingSilenceChunks = 0
                return .speechContinue
            } else {
                pendingSilenceChunks += 1
                if pendingSilenceChunks >= minSilenceChunks {
                    state = .silent
                    pendingSilenceChunks = 0
                    pendingSpeechChunks = 0
                    return .silenceStart
                }
                return .speechContinue  // still speaking (debouncing)
            }
        }
    }

    private func chunks(for duration: TimeInterval) -> Int {
        max(1, Int(duration / config.chunkDurationSeconds))
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter VoiceActivityDetectorTests`
Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/VoiceActivityDetector.swift Tests/ClaudeRelaySpeechTests/VoiceActivityDetectorTests.swift
git commit -m "feat(speech): add energy-based VoiceActivityDetector"
```

---

## Task 5: WakeWordDetector (fuzzy matching logic)

**Files:**
- Create: `Sources/ClaudeRelaySpeech/WakeWordDetector.swift`
- Create: `Tests/ClaudeRelaySpeechTests/WakeWordDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeRelaySpeechTests/WakeWordDetectorTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

private final class StubTranscriber: SpeechTranscribing {
    var result: String = ""
    var shouldThrow: Bool = false

    func transcribe(_ audioBuffer: [Float]) async throws -> String {
        if shouldThrow { throw TranscriberError.emptyTranscription }
        return result
    }
}

@MainActor
final class WakeWordDetectorTests: XCTestCase {

    func testExactMatchSucceeds() async {
        let stub = StubTranscriber()
        stub.result = "claude list my files"
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        switch result {
        case .detected(let residueText):
            XCTAssertEqual(residueText.trimmingCharacters(in: .whitespaces), "list my files")
        default:
            XCTFail("Expected detected result, got \(result)")
        }
    }

    func testEditDistanceOneMatches() async {
        let stub = StubTranscriber()
        stub.result = "claud tell me a joke"  // missing 'e'
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .detected = result { /* ok */ } else {
            XCTFail("Expected fuzzy match for 'claud' to succeed")
        }
    }

    func testEditDistanceTwoDoesNotMatch() async {
        let stub = StubTranscriber()
        stub.result = "clubs tell me a joke"  // 2+ edits from 'claude'
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .notDetected = result { /* ok */ } else {
            XCTFail("Expected non-match for 'clubs'")
        }
    }

    func testWakeWordMustAppearAtStart() async {
        let stub = StubTranscriber()
        stub.result = "hey there claude open a file"  // wake word in middle
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .notDetected = result { /* ok */ } else {
            XCTFail("Wake word in the middle should not trigger")
        }
    }

    func testCaseInsensitiveMatch() async {
        let stub = StubTranscriber()
        stub.result = "CLAUDE show status"
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .detected = result { /* ok */ } else {
            XCTFail("Expected case-insensitive match")
        }
    }

    func testEmptyTranscriptionReturnsNotDetected() async {
        let stub = StubTranscriber()
        stub.shouldThrow = true
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        let result = await detector.checkForWakeWord()

        if case .transcriptionFailed = result { /* ok */ } else {
            XCTFail("Expected transcriptionFailed on thrown error")
        }
    }

    func testEditDistanceOnBaseWord() {
        // Pure helper test — no async.
        XCTAssertEqual(WakeWordDetector.levenshtein("claude", "claude"), 0)
        XCTAssertEqual(WakeWordDetector.levenshtein("claude", "claud"), 1)
        XCTAssertEqual(WakeWordDetector.levenshtein("claude", "cloud"), 1)
        XCTAssertEqual(WakeWordDetector.levenshtein("claude", "clawed"), 2)
        XCTAssertEqual(WakeWordDetector.levenshtein("claude", "clubs"), 3)
    }

    func testResetClearsAudio() async {
        let stub = StubTranscriber()
        stub.result = "claude do a thing"
        let detector = WakeWordDetector(transcriber: stub, keyword: "claude")

        detector.feedAudio(Array(repeating: Float(0.2), count: 16000))
        detector.reset()

        let result = await detector.checkForWakeWord()
        if case .notDetected = result { /* ok — no audio to transcribe */ } else {
            XCTFail("Expected notDetected after reset")
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WakeWordDetectorTests`
Expected: FAIL — `WakeWordDetector` not defined.

- [ ] **Step 3: Implement WakeWordDetector**

Create `Sources/ClaudeRelaySpeech/WakeWordDetector.swift`:

```swift
import Foundation

/// Result of a single wake-word check.
public enum WakeWordResult: Equatable, Sendable {
    /// Wake word was found at the start of the transcription.
    /// `residueText` is the rest of the transcription after the wake word.
    case detected(residueText: String)
    case notDetected
    case transcriptionFailed
}

/// Listens for a wake word (e.g., "Claude") at the start of a spoken phrase.
///
/// Usage:
///   1. Call `feedAudio(_:)` with speech chunks while VAD reports speech.
///   2. When VAD reports silence or max window reached, call `checkForWakeWord()`.
///   3. If `.detected`, transition to recording state.
///   4. If `.notDetected`, call `reset()` before the next speech segment.
@MainActor
public final class WakeWordDetector {

    public let keyword: String
    public let maxListenWindowSeconds: TimeInterval

    private let transcriber: any SpeechTranscribing
    private let sampleRate: Double

    private var accumulator: [Float] = []

    public init(
        transcriber: any SpeechTranscribing,
        keyword: String = "claude",
        maxListenWindowSeconds: TimeInterval = 3.0,
        sampleRate: Double = 16000
    ) {
        self.transcriber = transcriber
        self.keyword = keyword.lowercased()
        self.maxListenWindowSeconds = maxListenWindowSeconds
        self.sampleRate = sampleRate
    }

    /// Append audio samples from the current speech segment.
    /// Automatically trims to the most recent `maxListenWindowSeconds`.
    public func feedAudio(_ samples: [Float]) {
        accumulator.append(contentsOf: samples)
        let maxSamples = Int(maxListenWindowSeconds * sampleRate)
        if accumulator.count > maxSamples {
            accumulator.removeFirst(accumulator.count - maxSamples)
        }
    }

    /// Run transcription and fuzzy-match the wake word at the start.
    public func checkForWakeWord() async -> WakeWordResult {
        guard !accumulator.isEmpty else { return .notDetected }

        let audio = accumulator
        let transcribed: String
        do {
            transcribed = try await transcriber.transcribe(audio)
        } catch {
            return .transcriptionFailed
        }

        return Self.match(transcript: transcribed, keyword: keyword)
    }

    /// Clear accumulated audio — call after .notDetected or after a
    /// successful detection transition.
    public func reset() {
        accumulator.removeAll(keepingCapacity: true)
    }

    // MARK: - Matching

    static func match(transcript: String, keyword: String) -> WakeWordResult {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .notDetected }

        let words = normalized.split(whereSeparator: { !$0.isLetter })
        guard let first = words.first else { return .notDetected }
        let firstWord = String(first)

        let distance = levenshtein(firstWord, keyword)
        let allowed = 1
        guard distance <= allowed else { return .notDetected }

        let residueWords = words.dropFirst().map(String.init)
        let residue = residueWords.joined(separator: " ")
        return .detected(residueText: residue)
    }

    /// Classic Levenshtein edit distance. Exposed for testing.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        if n == 0 { return m }
        if m == 0 { return n }

        var previous = Array(0...m)
        var current = Array(repeating: 0, count: m + 1)

        for i in 1...n {
            current[0] = i
            for j in 1...m {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,       // deletion
                    current[j - 1] + 1,    // insertion
                    previous[j - 1] + cost // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[m]
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter WakeWordDetectorTests`
Expected: All 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/WakeWordDetector.swift Tests/ClaudeRelaySpeechTests/WakeWordDetectorTests.swift
git commit -m "feat(speech): add WakeWordDetector with fuzzy matching"
```

---

## Task 6: TurnEndDetecting protocol + heuristic implementation

> **Context:** The Smart-Turn CoreML model is added in Task 14. To unblock the orchestrator, we first ship a heuristic-based `HeuristicTurnEndDetector` that simply says "done". Smart-Turn slots in as a drop-in replacement.

**Files:**
- Create: `Sources/ClaudeRelaySpeech/TurnEndDetector.swift`
- Create: `Tests/ClaudeRelaySpeechTests/TurnEndDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeRelaySpeechTests/TurnEndDetectorTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

@MainActor
final class TurnEndDetectorTests: XCTestCase {

    func testHeuristicAlwaysReturnsSpeakerDone() async {
        let detector = HeuristicTurnEndDetector()
        let audio = Array(repeating: Float(0.2), count: 16000)

        let result = await detector.predict(utteranceAudio: audio)
        XCTAssertEqual(result, .speakerDone(confidence: 1.0))
    }

    func testHeuristicHandlesShortAudio() async {
        let detector = HeuristicTurnEndDetector()
        let audio = Array(repeating: Float(0.1), count: 100)

        let result = await detector.predict(utteranceAudio: audio)
        XCTAssertEqual(result, .speakerDone(confidence: 1.0))
    }

    func testHeuristicHandlesEmptyAudio() async {
        let detector = HeuristicTurnEndDetector()
        let result = await detector.predict(utteranceAudio: [])
        XCTAssertEqual(result, .speakerDone(confidence: 1.0))
    }

    func testTurnEndResultEquatable() {
        XCTAssertEqual(
            TurnEndResult.speakerDone(confidence: 0.9),
            TurnEndResult.speakerDone(confidence: 0.9)
        )
        XCTAssertNotEqual(
            TurnEndResult.speakerDone(confidence: 0.9),
            TurnEndResult.speakerContinuing(confidence: 0.9)
        )
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TurnEndDetectorTests`
Expected: FAIL — types not defined.

- [ ] **Step 3: Implement the protocol and heuristic detector**

Create `Sources/ClaudeRelaySpeech/TurnEndDetector.swift`:

```swift
import Foundation

/// Result of predicting whether a speaker is finished with their turn.
public enum TurnEndResult: Equatable, Sendable {
    case speakerDone(confidence: Float)
    case speakerContinuing(confidence: Float)

    public var isDone: Bool {
        if case .speakerDone = self { return true }
        return false
    }
}

/// Protocol for turn-end detection — enables swapping heuristic ↔ ML model.
public protocol TurnEndDetecting: AnyObject, Sendable {
    /// Predict whether the speaker has finished their turn.
    /// The audio should be 16 kHz mono. Up to the last 8 seconds are used.
    func predict(utteranceAudio: [Float]) async -> TurnEndResult
}

/// Fallback turn-end detector that always signals "speaker done".
///
/// Used when the Smart-Turn CoreML model is not bundled or fails to load.
/// The orchestrator's hard silence timeout still bounds recording length,
/// so this degrades gracefully to "stop after N seconds of silence".
public final class HeuristicTurnEndDetector: TurnEndDetecting, @unchecked Sendable {

    public init() {}

    public func predict(utteranceAudio: [Float]) async -> TurnEndResult {
        .speakerDone(confidence: 1.0)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter TurnEndDetectorTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/TurnEndDetector.swift Tests/ClaudeRelaySpeechTests/TurnEndDetectorTests.swift
git commit -m "feat(speech): add TurnEndDetecting protocol and heuristic detector"
```

---

## Task 7: ContinuousListeningEngine — init, enable/disable, state

**Files:**
- Create: `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`
- Create: `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift`
- Create: `Tests/ClaudeRelaySpeechTests/MockVADAndDetectors.swift`

- [ ] **Step 1: Write the mock helpers**

Create `Tests/ClaudeRelaySpeechTests/MockVADAndDetectors.swift`:

```swift
import Foundation
@testable import ClaudeRelaySpeech

final class MockVAD: VoiceActivityDetecting, @unchecked Sendable {
    var eventsToReturn: [VADEvent] = []
    var processedChunks = 0
    var resetCallCount = 0

    func process(chunk: [Float]) -> VADEvent {
        processedChunks += 1
        guard !eventsToReturn.isEmpty else { return .silenceContinue }
        return eventsToReturn.removeFirst()
    }

    func reset() { resetCallCount += 1 }
}

final class MockTurnEndDetector: TurnEndDetecting, @unchecked Sendable {
    var resultToReturn: TurnEndResult = .speakerDone(confidence: 1.0)
    var predictCallCount = 0

    func predict(utteranceAudio: [Float]) async -> TurnEndResult {
        predictCallCount += 1
        return resultToReturn
    }
}

final class StubSpeechTranscriber: SpeechTranscribing, @unchecked Sendable {
    var result: String = ""
    var shouldThrow = false
    var callCount = 0

    func transcribe(_ audioBuffer: [Float]) async throws -> String {
        callCount += 1
        if shouldThrow { throw TranscriberError.emptyTranscription }
        return result
    }
}

final class StubTextCleaner: TextCleaning, @unchecked Sendable {
    var result: String?
    var callCount = 0

    func clean(_ text: String) async throws -> String {
        callCount += 1
        return result ?? text
    }
}
```

- [ ] **Step 2: Write the failing engine tests**

Create `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

@MainActor
final class ContinuousListeningEngineTests: XCTestCase {

    private func makeEngine(
        vad: MockVAD = MockVAD(),
        turnEnd: MockTurnEndDetector = MockTurnEndDetector(),
        transcriber: StubSpeechTranscriber = StubSpeechTranscriber(),
        cleaner: StubTextCleaner = StubTextCleaner()
    ) -> ContinuousListeningEngine {
        ContinuousListeningEngine(
            vad: vad,
            wakeWordDetector: WakeWordDetector(transcriber: transcriber, keyword: "claude"),
            turnEndDetector: turnEnd,
            transcriber: transcriber,
            cleaner: cleaner
        )
    }

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
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter ContinuousListeningEngineTests`
Expected: FAIL — `ContinuousListeningEngine` not defined.

- [ ] **Step 4: Implement the engine skeleton**

Create `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`:

```swift
import Foundation
import AVFoundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Orchestrates the continuous listening pipeline: VAD → wake-word →
/// recording → turn-end → transcription → cleanup → output.
///
/// The mic stays open across all states while `enable()`d. State transitions
/// are driven by VAD events and detector async callbacks.
@MainActor
public final class ContinuousListeningEngine: ObservableObject {

    @Published public private(set) var state: ContinuousListeningState = .idle

    /// Called with the final, cleaned utterance text after each turn.
    public var onUtteranceReady: ((String) -> Void)?

    // Pipeline collaborators
    private let vad: any VoiceActivityDetecting
    private let wakeWordDetector: WakeWordDetector
    private let turnEndDetector: any TurnEndDetecting
    private let transcriber: any SpeechTranscribing
    private let cleaner: any TextCleaning

    // Audio buffer shared across consumers
    private let audioBuffer: StreamingAudioBuffer

    // Utterance tracking
    private var utteranceStartPosition: Int = 0
    private var wakeWordResidue: String = ""

    // MARK: - Init

    public init(
        vad: any VoiceActivityDetecting,
        wakeWordDetector: WakeWordDetector,
        turnEndDetector: any TurnEndDetecting,
        transcriber: any SpeechTranscribing,
        cleaner: any TextCleaning,
        bufferCapacitySeconds: TimeInterval = 10.0,
        sampleRate: Double = 16000
    ) {
        self.vad = vad
        self.wakeWordDetector = wakeWordDetector
        self.turnEndDetector = turnEndDetector
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.audioBuffer = StreamingAudioBuffer(
            capacitySeconds: bufferCapacitySeconds,
            sampleRate: sampleRate
        )
    }

    // MARK: - Lifecycle

    public func enable() async {
        guard state == .idle else { return }
        vad.reset()
        wakeWordDetector.reset()
        state = .listening
    }

    public func disable() async {
        guard state != .idle else { return }
        vad.reset()
        wakeWordDetector.reset()
        state = .idle
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter ContinuousListeningEngineTests`
Expected: 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift Tests/ClaudeRelaySpeechTests/MockVADAndDetectors.swift
git commit -m "feat(speech): scaffold ContinuousListeningEngine with enable/disable"
```

---

## Task 8: Engine — VAD-driven state transitions

> **Goal:** Feed the engine audio chunks directly (via a test-friendly entry point), let it run VAD, and walk through the state machine. No real AVAudioEngine integration yet — that lands in Task 10.

**Files:**
- Modify: `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`
- Modify: `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift`

- [ ] **Step 1: Add failing tests for the VAD-driven transitions**

Append to `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift` (inside the existing class):

```swift
    // MARK: - VAD-driven transitions

    func testSpeechStartTransitionsToDetectingWakeWord() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = ""   // no wake word
        let engine = makeEngine(vad: vad, transcriber: transcriber)
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

        vad.eventsToReturn = [.speechStart, .speechContinue, .silenceStart]
        for _ in 0..<3 {
            await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        }
        await engine.waitForPendingWork()

        XCTAssertEqual(engine.state, .listening)
    }

    func testWakeWordTransitionsOutOfDetectingWakeWord() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude open a file"
        let engine = makeEngine(vad: vad, transcriber: transcriber)
        await engine.enable()

        vad.eventsToReturn = [.speechStart, .speechContinue, .silenceStart]
        for _ in 0..<3 {
            await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        }
        await engine.waitForPendingWork()

        // We should have transitioned out of detectingWakeWord and listening.
        XCTAssertNotEqual(engine.state, .detectingWakeWord)
        XCTAssertNotEqual(engine.state, .listening)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ContinuousListeningEngineTests`
Expected: FAIL — `ingest(chunk:)` and `waitForPendingWork()` not defined.

- [ ] **Step 3: Extend engine with ingest and transitions**

Edit `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`. Add this field after `private var wakeWordResidue: String = ""`:

```swift
    /// Task spawned for wake-word check / turn-end check / transcription.
    /// Tracked so tests can await completion and disable() can cancel cleanly.
    private var pendingTask: Task<Void, Never>?
```

Then add the ingest method and state-transition helpers at the bottom of the class (before the closing brace):

```swift
    // MARK: - Audio ingestion

    /// Process one audio chunk. In production, called from the audio-engine tap;
    /// in tests, called directly with synthetic samples.
    public func ingest(chunk: [Float]) async {
        guard state != .idle else { return }

        audioBuffer.append(chunk)

        // Always feed VAD; its event drives the state machine.
        let event = vad.process(chunk: chunk)

        switch state {
        case .listening:
            if event == .speechStart {
                utteranceStartPosition = audioBuffer.currentPosition
                wakeWordDetector.reset()
                wakeWordDetector.feedAudio(chunk)
                state = .detectingWakeWord
            }

        case .detectingWakeWord:
            wakeWordDetector.feedAudio(chunk)
            if event == .silenceStart {
                // Phrase ended — check if it started with wake word.
                runWakeWordCheck()
            }

        case .recording:
            if event == .silenceStart {
                state = .detectingTurnEnd
                runTurnEndCheck()
            }

        case .detectingTurnEnd:
            // If speech resumes before turn-end prediction finishes, go back to recording.
            if event == .speechStart {
                state = .recording
            }

        case .idle, .transcribing, .cleaning, .outputting, .error:
            break
        }
    }

    /// Await any in-flight async work (wake-word check, turn-end prediction,
    /// transcription, cleanup). Public for tests.
    public func waitForPendingWork() async {
        await pendingTask?.value
    }

    // MARK: - Pipeline steps

    private func runWakeWordCheck() {
        pendingTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.wakeWordDetector.checkForWakeWord()
            guard !Task.isCancelled else { return }
            self.handleWakeWordResult(result)
        }
    }

    private func handleWakeWordResult(_ result: WakeWordResult) {
        switch result {
        case .detected(let residue):
            wakeWordResidue = residue
            // The first silence already bracketed the phrase, so jump straight
            // to turn-end prediction to decide whether the whole utterance is done.
            state = .detectingTurnEnd
            runTurnEndCheck()
        case .notDetected, .transcriptionFailed:
            wakeWordDetector.reset()
            state = .listening
        }
    }

    private func runTurnEndCheck() {
        pendingTask = Task { [weak self] in
            guard let self else { return }
            let utterance = self.audioBuffer.audioSince(position: self.utteranceStartPosition)
            let result = await self.turnEndDetector.predict(utteranceAudio: utterance)
            guard !Task.isCancelled else { return }
            self.handleTurnEndResult(result, utterance: utterance)
        }
    }

    private func handleTurnEndResult(_ result: TurnEndResult, utterance: [Float]) {
        switch result {
        case .speakerDone:
            runTranscription(utterance: utterance)
        case .speakerContinuing:
            state = .recording
        }
    }

    private func runTranscription(utterance: [Float]) {
        state = .transcribing
        pendingTask = Task { [weak self] in
            guard let self else { return }
            let rawText: String
            do {
                rawText = try await self.transcriber.transcribe(utterance)
            } catch {
                self.state = .listening
                return
            }
            guard !Task.isCancelled else { return }

            self.state = .cleaning
            let cleaned: String
            do {
                cleaned = try await self.cleaner.clean(rawText)
            } catch {
                cleaned = rawText
            }
            guard !Task.isCancelled else { return }

            self.state = .outputting
            self.onUtteranceReady?(cleaned)
            self.wakeWordDetector.reset()
            self.vad.reset()
            self.state = .listening
        }
    }
```

Also update `disable()` to cancel the pending task. Replace the existing `disable()` implementation with:

```swift
    public func disable() async {
        guard state != .idle else { return }
        pendingTask?.cancel()
        pendingTask = nil
        vad.reset()
        wakeWordDetector.reset()
        state = .idle
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ContinuousListeningEngineTests`
Expected: All 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift
git commit -m "feat(speech): drive ContinuousListeningEngine state machine from VAD events"
```

---

## Task 9: Engine — end-to-end callback test

**Files:**
- Modify: `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift`

- [ ] **Step 1: Write the end-to-end callback test**

Append to `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift`:

```swift
    // MARK: - End-to-end

    func testFullPipelineDeliversCleanedText() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude list my files"
        let cleaner = StubTextCleaner()
        cleaner.result = "List my files"
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
        engine.onUtteranceReady = { text in delivered = text }

        // Simulate: speechStart → speechContinue → silenceStart
        vad.eventsToReturn = [.speechStart, .speechContinue, .silenceStart]
        for _ in 0..<3 {
            await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        }
        // After wake-word check → turn-end → transcription → cleanup, await each stage.
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()
        await engine.waitForPendingWork()

        XCTAssertEqual(delivered, "List my files")
        XCTAssertEqual(engine.state, .listening)
    }

    func testSpeakerContinuingKeepsRecording() async {
        let vad = MockVAD()
        let transcriber = StubSpeechTranscriber()
        transcriber.result = "claude open the door"
        let turnEnd = MockTurnEndDetector()
        turnEnd.resultToReturn = .speakerContinuing(confidence: 0.8)

        let engine = makeEngine(vad: vad, turnEnd: turnEnd, transcriber: transcriber)
        await engine.enable()

        vad.eventsToReturn = [.speechStart, .silenceStart]
        await engine.ingest(chunk: Array(repeating: Float(0.3), count: 480))
        await engine.ingest(chunk: Array(repeating: Float(0.1), count: 480))
        await engine.waitForPendingWork()
        // runTurnEndCheck fires a new pendingTask; await it.
        await engine.waitForPendingWork()

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
        // Disable immediately, before pending task completes
        await engine.disable()

        XCTAssertEqual(engine.state, .idle)
    }
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter ContinuousListeningEngineTests`
Expected: All 11 tests pass. Engine logic added in Task 8 already supports these — this task verifies the end-to-end flow.

- [ ] **Step 3: Commit**

```bash
git add Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift
git commit -m "test(speech): cover full pipeline and cancellation in ContinuousListeningEngine"
```

---

## Task 10: Engine — real AudioSource integration

> **Context:** The engine has been tested with synthetic chunks via `ingest(_:)`. This task wires up a real `AVAudioEngine` audio tap that calls `ingest(_:)` for each 16 kHz mono Float32 chunk. We extract the audio plumbing into a small internal type so it stays unit-testable.

**Files:**
- Create: `Sources/ClaudeRelaySpeech/StreamingAudioSource.swift`
- Modify: `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`
- Modify: `Tests/ClaudeRelaySpeechTests/MockVADAndDetectors.swift`
- Modify: `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift`

- [ ] **Step 1: Create StreamingAudioSource**

Create `Sources/ClaudeRelaySpeech/StreamingAudioSource.swift`:

```swift
import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Protocol used by the engine to receive streaming audio.
/// The real implementation wraps AVAudioEngine; tests can substitute a no-op.
public protocol StreamingAudioSourcing: AnyObject, Sendable {
    /// Set the callback that receives 16 kHz mono Float32 chunks.
    /// The source may emit larger chunks if the hardware delivers larger
    /// buffers; callers should handle any size.
    var onChunk: ((@Sendable ([Float]) -> Void))? { get set }

    func start() throws
    func stop()
}

/// Error cases for audio source setup.
public enum StreamingAudioSourceError: Error, LocalizedError {
    case formatCreationFailed
    case converterCreationFailed

    public var errorDescription: String? {
        switch self {
        case .formatCreationFailed:   return "Failed to create 16 kHz target audio format"
        case .converterCreationFailed: return "Failed to create audio format converter"
        }
    }
}

/// Production audio source backed by AVAudioEngine. Configures a 16 kHz
/// mono Float32 tap on the hardware input node and forwards chunks to
/// the engine via `onChunk`.
public final class StreamingAudioSource: StreamingAudioSourcing, @unchecked Sendable {

    public var onChunk: ((@Sendable ([Float]) -> Void))?

    private let audioEngine = AVAudioEngine()
    private var isRunning = false

    public init() {}

    public func start() throws {
        guard !isRunning else { return }

        #if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
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

    public func stop() {
        guard isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false

        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        #endif
    }

    // MARK: - Private

    static func convert(
        _ pcmBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> [Float] {
        let frameCount = AVAudioFrameCount(
            Double(pcmBuffer.frameLength) * 16000.0 / pcmBuffer.format.sampleRate
        )
        guard frameCount > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
        else { return [] }

        var hasData = true
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return pcmBuffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard error == nil, let channelData = converted.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(converted.frameLength)
        ))
    }
}
```

- [ ] **Step 2: Integrate the source into ContinuousListeningEngine**

Open `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`.

Add a field after `private var pendingTask: Task<Void, Never>?`:

```swift
    private let audioSource: any StreamingAudioSourcing
```

Replace the existing init with:

```swift
    public init(
        vad: any VoiceActivityDetecting,
        wakeWordDetector: WakeWordDetector,
        turnEndDetector: any TurnEndDetecting,
        transcriber: any SpeechTranscribing,
        cleaner: any TextCleaning,
        audioSource: (any StreamingAudioSourcing)? = nil,
        bufferCapacitySeconds: TimeInterval = 10.0,
        sampleRate: Double = 16000
    ) {
        self.vad = vad
        self.wakeWordDetector = wakeWordDetector
        self.turnEndDetector = turnEndDetector
        self.transcriber = transcriber
        self.cleaner = cleaner
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

Replace `enable()` with:

```swift
    public func enable() async {
        guard state == .idle else { return }
        vad.reset()
        wakeWordDetector.reset()
        do {
            try audioSource.start()
            state = .listening
        } catch {
            state = .error(error.localizedDescription)
        }
    }
```

Replace `disable()` with:

```swift
    public func disable() async {
        guard state != .idle else { return }
        pendingTask?.cancel()
        pendingTask = nil
        audioSource.stop()
        vad.reset()
        wakeWordDetector.reset()
        state = .idle
    }
```

- [ ] **Step 3: Add a no-op audio source for tests**

Append to `Tests/ClaudeRelaySpeechTests/MockVADAndDetectors.swift`:

```swift
final class NoopAudioSource: StreamingAudioSourcing, @unchecked Sendable {
    var onChunk: (@Sendable ([Float]) -> Void)?
    var startCallCount = 0
    var stopCallCount = 0

    func start() throws { startCallCount += 1 }
    func stop() { stopCallCount += 1 }
}
```

- [ ] **Step 4: Update existing tests to pass the no-op audio source**

In `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift`, replace the `makeEngine` helper with:

```swift
    private func makeEngine(
        vad: MockVAD = MockVAD(),
        turnEnd: MockTurnEndDetector = MockTurnEndDetector(),
        transcriber: StubSpeechTranscriber = StubSpeechTranscriber(),
        cleaner: StubTextCleaner = StubTextCleaner(),
        audioSource: NoopAudioSource = NoopAudioSource()
    ) -> ContinuousListeningEngine {
        ContinuousListeningEngine(
            vad: vad,
            wakeWordDetector: WakeWordDetector(transcriber: transcriber, keyword: "claude"),
            turnEndDetector: turnEnd,
            transcriber: transcriber,
            cleaner: cleaner,
            audioSource: audioSource
        )
    }
```

- [ ] **Step 5: Add source-lifecycle tests**

Append to `ContinuousListeningEngineTests.swift`:

```swift
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
```

- [ ] **Step 6: Run tests to verify everything passes**

Run: `swift test --filter ClaudeRelaySpeechTests`
Expected: All tests pass (baseline 11 engine tests + 2 new source lifecycle tests + the other suites).

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeRelaySpeech/StreamingAudioSource.swift Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift Tests/ClaudeRelaySpeechTests/MockVADAndDetectors.swift Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift
git commit -m "feat(speech): wire real AVAudioEngine source into ContinuousListeningEngine"
```

---

## Task 11: Add continuous listening settings to AppSettings

**Files:**
- Modify: `ClaudeRelayApp/Models/AppSettings.swift`
- Create: `ClaudeRelayAppTests/AppSettingsContinuousTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ClaudeRelayAppTests/AppSettingsContinuousTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayApp

@MainActor
final class AppSettingsContinuousTests: XCTestCase {

    func testContinuousListeningDefaultsToFalse() {
        UserDefaults.standard.removeObject(forKey: "continuousListeningEnabled")
        XCTAssertFalse(AppSettings.shared.continuousListeningEnabled)
    }

    func testWakeWordDefaultsToClaude() {
        UserDefaults.standard.removeObject(forKey: "wakeWord")
        XCTAssertEqual(AppSettings.shared.wakeWord, "claude")
    }

    func testTurnEndSilenceTimeoutDefaults() {
        UserDefaults.standard.removeObject(forKey: "turnEndSilenceTimeout")
        XCTAssertEqual(AppSettings.shared.turnEndSilenceTimeout, 1.5, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Open the Xcode project, run the `ClaudeRelayAppTests` bundle (or use `xcodebuild test`). Expected: FAIL — `continuousListeningEnabled`, `wakeWord`, `turnEndSilenceTimeout` not defined on `AppSettings`.

- [ ] **Step 3: Add the settings**

Open `ClaudeRelayApp/Models/AppSettings.swift`. Add these lines after the existing `@AppStorage` declarations (after `recordingShortcutKey`):

```swift
    // MARK: - Continuous Listening

    @AppStorage("continuousListeningEnabled") var continuousListeningEnabled = false
    @AppStorage("wakeWord") var wakeWord: String = "claude"
    /// Max silence (seconds) before the engine hard-stops a recording,
    /// regardless of the turn-end classifier's prediction.
    @AppStorage("turnEndSilenceTimeout") var turnEndSilenceTimeout: Double = 1.5
```

- [ ] **Step 4: Run to verify pass**

Re-run the test target. Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayApp/Models/AppSettings.swift ClaudeRelayAppTests/AppSettingsContinuousTests.swift
git commit -m "feat(ios): add continuous listening settings to AppSettings"
```

---

## Task 12: Convert Silero VAD to CoreML (offline, one-time)

> **Context:** This task runs a Python conversion script once to produce `SileroVAD.mlpackage`. The script lives in `tools/speech/` and uses `coremltools`. The resulting model file is committed to the repo under `Sources/ClaudeRelaySpeech/Resources/`.
>
> **If this step fails or the ONNX model export is non-trivial, proceed without it** — the engine already works with the energy-based VAD. A follow-up issue can track the CoreML integration.

**Files:**
- Create: `tools/speech/convert_silero_vad.py`
- Create: `tools/speech/README.md`
- Create: `Sources/ClaudeRelaySpeech/Resources/SileroVAD.mlpackage` (binary artifact)
- Modify: `Package.swift` (add resources)

- [ ] **Step 1: Write the conversion script**

Create `tools/speech/convert_silero_vad.py`:

```python
#!/usr/bin/env python3
"""
Convert Silero VAD to CoreML for on-device use.

Usage:
    pip install torch onnx coremltools silero-vad
    python tools/speech/convert_silero_vad.py

Produces: Sources/ClaudeRelaySpeech/Resources/SileroVAD.mlpackage
"""
from pathlib import Path

import torch
import coremltools as ct
from silero_vad import load_silero_vad

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = REPO_ROOT / "Sources" / "ClaudeRelaySpeech" / "Resources"
OUT_PATH = OUT_DIR / "SileroVAD.mlpackage"

def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    print("[1/3] Loading Silero VAD (PyTorch)...")
    model = load_silero_vad()
    model.eval()

    # Silero VAD input: audio chunk + sampling rate scalar.
    # For CoreML we pin the input size to 480 samples (30 ms @ 16 kHz).
    example_audio = torch.randn(1, 480)
    example_sr = torch.tensor(16000)

    print("[2/3] Tracing model...")
    traced = torch.jit.trace(model, (example_audio, example_sr), strict=False)

    print("[3/3] Converting to CoreML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="audio", shape=(1, 480), dtype=ct.models.datatypes.float32),
        ],
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.save(str(OUT_PATH))
    print(f"Wrote {OUT_PATH}")

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Write the README**

Create `tools/speech/README.md`:

```markdown
# Speech Model Conversion Tools

One-time scripts that convert third-party models to CoreML for bundling
with `ClaudeRelaySpeech`. Output artifacts are committed to the repo so
CI doesn't need a Python toolchain.

## Prerequisites

```bash
pip install torch onnx coremltools silero-vad
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

- [ ] **Step 3: Run the script**

Run: `python tools/speech/convert_silero_vad.py`
Expected: writes `Sources/ClaudeRelaySpeech/Resources/SileroVAD.mlpackage`.

If conversion fails due to tracing issues, skip the rest of this task and mark it as **deferred** (we still have the energy-based VAD).

- [ ] **Step 4: Register resources in Package.swift**

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

- [ ] **Step 5: Run the build to verify**

Run: `swift build`
Expected: successful build, `.mlpackage` is copied into the bundle.

- [ ] **Step 6: Commit**

```bash
git add tools/speech Sources/ClaudeRelaySpeech/Resources/SileroVAD.mlpackage Package.swift
git commit -m "feat(speech): convert Silero VAD to CoreML and bundle with speech target"
```

---

## Task 13: SileroVoiceActivityDetector (CoreML-backed, with fallback)

**Files:**
- Create: `Sources/ClaudeRelaySpeech/SileroVoiceActivityDetector.swift`
- Create: `Tests/ClaudeRelaySpeechTests/SileroVoiceActivityDetectorTests.swift`

> **Context:** If Task 12 was deferred (model couldn't be converted), **skip this task entirely** — the engine defaults to `VoiceActivityDetector`.

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeRelaySpeechTests/SileroVoiceActivityDetectorTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

final class SileroVoiceActivityDetectorTests: XCTestCase {

    func testLoadsBundledModel() {
        let vad = SileroVoiceActivityDetector()
        XCTAssertNotNil(vad, "Bundled SileroVAD.mlpackage should load successfully")
    }

    func testProducesEventsForSilenceAndSpeech() {
        guard let vad = SileroVoiceActivityDetector() else {
            XCTFail("Bundled SileroVAD.mlpackage failed to load")
            return
        }

        let silence = Array(repeating: Float(0.0), count: 480)
        let _ = vad.process(chunk: silence)  // should not crash

        let speech = (0..<480).map { Float(sin(Double($0) * 0.1)) * 0.4 }
        let _ = vad.process(chunk: speech)   // should not crash
    }

    func testResetDoesNotCrash() {
        guard let vad = SileroVoiceActivityDetector() else { return }
        vad.reset()
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SileroVoiceActivityDetectorTests`
Expected: FAIL — `SileroVoiceActivityDetector` not defined.

- [ ] **Step 3: Implement the CoreML-backed VAD**

Create `Sources/ClaudeRelaySpeech/SileroVoiceActivityDetector.swift`:

```swift
import Foundation
import CoreML

/// Silero VAD wrapper that delegates hysteresis and debouncing to the
/// energy-based `VoiceActivityDetector`. The CoreML model produces a
/// raw speech probability per 30 ms chunk; we feed that probability
/// into the base state machine as if it were RMS energy.
public final class SileroVoiceActivityDetector: VoiceActivityDetecting, @unchecked Sendable {

    private let inner: VoiceActivityDetector
    private let model: MLModel

    public convenience init?(config: VoiceActivityDetector.Config = .init()) {
        guard let url = Bundle.module.url(forResource: "SileroVAD", withExtension: "mlpackage"),
              let loaded = try? MLModel(contentsOf: url) else {
            return nil
        }
        self.init(model: loaded, config: config)
    }

    init(model: MLModel, config: VoiceActivityDetector.Config) {
        self.model = model
        var cfg = config
        // The CoreML model replaces energy scoring, so thresholds apply to its
        // probability output in the 0..1 range.
        cfg.speechThreshold = 0.5
        cfg.silenceThreshold = 0.35
        self.inner = VoiceActivityDetector(config: cfg)
    }

    public func process(chunk: [Float]) -> VADEvent {
        let probability = predict(chunk: chunk)
        // Feed the probability as "energy" so the base class's hysteresis /
        // debouncing apply to the model's output unchanged.
        return inner.process(chunk: Array(repeating: probability, count: chunk.count))
    }

    public func reset() { inner.reset() }

    // MARK: - CoreML

    private func predict(chunk: [Float]) -> Float {
        guard chunk.count == 480 else { return 0.0 }
        do {
            let input = try MLMultiArray(shape: [1, 480], dataType: .float32)
            for i in 0..<480 {
                input[i] = NSNumber(value: chunk[i])
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": input])
            let output = try model.prediction(from: provider)
            // The output feature name depends on how the model was exported —
            // check both common variants.
            if let value = output.featureValue(for: "output")?.multiArrayValue,
               value.count > 0 {
                return Float(truncating: value[0])
            }
            if let value = output.featureValue(for: "prob")?.multiArrayValue,
               value.count > 0 {
                return Float(truncating: value[0])
            }
            return 0.0
        } catch {
            return 0.0
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter SileroVoiceActivityDetectorTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/SileroVoiceActivityDetector.swift Tests/ClaudeRelaySpeechTests/SileroVoiceActivityDetectorTests.swift
git commit -m "feat(speech): add CoreML-backed SileroVoiceActivityDetector"
```

---

## Task 14: Smart-Turn CoreML conversion + SmartTurnTurnEndDetector

> **Note:** Structurally identical to Tasks 12 + 13. If either model conversion is non-trivial for the contributor, this task can be **deferred** without blocking the feature — the engine defaults to `HeuristicTurnEndDetector`.

**Files:**
- Create: `tools/speech/convert_smart_turn.py`
- Create: `Sources/ClaudeRelaySpeech/Resources/SmartTurn.mlpackage`
- Create: `Sources/ClaudeRelaySpeech/SmartTurnTurnEndDetector.swift`
- Create: `Tests/ClaudeRelaySpeechTests/SmartTurnTurnEndDetectorTests.swift`
- Modify: `Package.swift` (add SmartTurn resource)

- [ ] **Step 1: Write the conversion script**

Create `tools/speech/convert_smart_turn.py`:

```python
#!/usr/bin/env python3
"""
Convert pipecat-ai/smart-turn to CoreML.

Fetches the int8-quantized ONNX model from the smart-turn releases, converts
it to CoreML, and writes to the speech target's Resources directory.
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
Expected: writes `Sources/ClaudeRelaySpeech/Resources/SmartTurn.mlpackage`.

If the download or conversion fails, skip the rest and mark the task deferred.

- [ ] **Step 3: Register the resource**

Open `Package.swift` and extend the `resources` array on `ClaudeRelaySpeech`:

```swift
resources: [
    .copy("Resources/SileroVAD.mlpackage"),
    .copy("Resources/SmartTurn.mlpackage"),
]
```

- [ ] **Step 4: Write the failing detector test**

Create `Tests/ClaudeRelaySpeechTests/SmartTurnTurnEndDetectorTests.swift`:

```swift
import XCTest
@testable import ClaudeRelaySpeech

@MainActor
final class SmartTurnTurnEndDetectorTests: XCTestCase {

    func testModelLoadsFromBundle() {
        let detector = SmartTurnTurnEndDetector()
        XCTAssertNotNil(detector)
    }

    func testPredictDoesNotCrashOnShortAudio() async {
        guard let detector = SmartTurnTurnEndDetector() else { return }
        let audio = Array(repeating: Float(0.1), count: 4000)
        let result = await detector.predict(utteranceAudio: audio)
        // Either outcome is acceptable — we're just verifying no crash
        // and that it returns something sensible.
        switch result {
        case .speakerDone, .speakerContinuing: break
        }
    }
}
```

- [ ] **Step 5: Run to verify failure**

Run: `swift test --filter SmartTurnTurnEndDetectorTests`
Expected: FAIL — type not defined.

- [ ] **Step 6: Implement SmartTurnTurnEndDetector**

Create `Sources/ClaudeRelaySpeech/SmartTurnTurnEndDetector.swift`:

```swift
import Foundation
import CoreML

/// Smart-Turn classifier wrapper. Predicts the probability that the
/// speaker has finished their turn given up to 8 seconds of context.
public final class SmartTurnTurnEndDetector: TurnEndDetecting, @unchecked Sendable {

    private static let requiredSampleCount = 128_000  // 8 s @ 16 kHz
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

    // MARK: - Helpers

    static func padOrTruncate(_ samples: [Float], toCount n: Int) -> [Float] {
        if samples.count == n { return samples }
        if samples.count > n {
            return Array(samples.suffix(n))
        }
        // Zero-pad at the start (model expects newest audio at the end).
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
            if let value = output.featureValue(for: "endpoint_probability")?.multiArrayValue,
               value.count > 0 {
                return Float(truncating: value[0])
            }
            if let value = output.featureValue(for: "output")?.multiArrayValue,
               value.count > 0 {
                return Float(truncating: value[0])
            }
            return 1.0  // default to "done" if we can't read the output
        } catch {
            return 1.0
        }
    }
}
```

- [ ] **Step 7: Run to verify pass**

Run: `swift test --filter SmartTurnTurnEndDetectorTests`
Expected: 2 tests pass.

- [ ] **Step 8: Commit**

```bash
git add tools/speech/convert_smart_turn.py Sources/ClaudeRelaySpeech/Resources/SmartTurn.mlpackage Sources/ClaudeRelaySpeech/SmartTurnTurnEndDetector.swift Tests/ClaudeRelaySpeechTests/SmartTurnTurnEndDetectorTests.swift Package.swift
git commit -m "feat(speech): add Smart-Turn CoreML wrapper with heuristic fallback"
```

---

## Task 15: Public factory for production engine

**Files:**
- Modify: `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`
- Modify: `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift`

> **Context:** App code should be able to create a fully-configured engine without touching implementation details. The factory picks the best available VAD and turn-end detector, with graceful fallbacks.

- [ ] **Step 1: Write the failing test**

Append to `Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift`:

```swift
    func testMakeDefaultReturnsEngine() {
        let engine = ContinuousListeningEngine.makeDefault()
        XCTAssertEqual(engine.state, .idle)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ContinuousListeningEngineTests`
Expected: FAIL — `makeDefault` not defined.

- [ ] **Step 3: Add the factory**

Open `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift`. Append to the class (before the closing brace):

```swift
    // MARK: - Factory

    /// Production factory: picks Silero-VAD + Smart-Turn when bundled, else
    /// falls back to energy-based VAD + heuristic turn-end detection.
    public static func makeDefault(
        keyword: String = "claude"
    ) -> ContinuousListeningEngine {
        let vad: any VoiceActivityDetecting = SileroVoiceActivityDetector() ?? VoiceActivityDetector()
        let turnEnd: any TurnEndDetecting = SmartTurnTurnEndDetector() ?? HeuristicTurnEndDetector()
        let transcriber = WhisperTranscriber.shared
        let cleaner = TextCleaner.shared
        let wakeWord = WakeWordDetector(transcriber: transcriber, keyword: keyword)

        return ContinuousListeningEngine(
            vad: vad,
            wakeWordDetector: wakeWord,
            turnEndDetector: turnEnd,
            transcriber: transcriber,
            cleaner: cleaner
        )
    }
```

> **Fallback note:** If Task 13 (or 14) was deferred, remove the `SileroVoiceActivityDetector()` (or `SmartTurnTurnEndDetector()`) half of the `??` expression and use only the fallback.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ContinuousListeningEngineTests`
Expected: all engine tests pass (baseline tests + new factory test).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift Tests/ClaudeRelaySpeechTests/ContinuousListeningEngineTests.swift
git commit -m "feat(speech): add ContinuousListeningEngine.makeDefault factory"
```

---

## Task 16: iOS — wire ContinuousListeningEngine into ActiveTerminalView

**Files:**
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift`
- Modify: `ClaudeRelayApp/Views/Components/MicButton.swift`

- [ ] **Step 1: Add the continuous engine to ActiveTerminalView**

Open `ClaudeRelayApp/Views/ActiveTerminalView.swift`. Add a StateObject for the continuous engine next to the existing `speechEngine`:

```swift
    @StateObject private var continuousEngine = ContinuousListeningEngine.makeDefault()
```

Add a computed `continuousTaskID` property outside the body:

```swift
    /// Re-runs the continuous engine .task on any of these changes.
    private var continuousTaskID: String {
        "\(settings.continuousListeningEnabled)-\(scenePhase)"
    }
```

Add a `.task(id:)` modifier on the main view body (below existing `.onChange` / `.task` modifiers). The modifier installs the callback and enables/disables based on settings + scene phase:

```swift
        .task(id: continuousTaskID) {
            continuousEngine.onUtteranceReady = { text in
                guard let id = coordinator.activeSessionId,
                      let vm = coordinator.viewModel(for: id) else { return }
                vm.sendInput(text)
            }
            if settings.continuousListeningEnabled && scenePhase == .active {
                await continuousEngine.enable()
            } else {
                await continuousEngine.disable()
            }
        }
```

- [ ] **Step 2: Extend MicButton to show the continuous state**

Open `ClaudeRelayApp/Views/Components/MicButton.swift`. Add a new stored parameter at the top:

```swift
    @ObservedObject var continuousEngine: ContinuousListeningEngine
```

Add an overlay to the existing button label (append `.overlay` to the `clipShape(Circle())` chain):

```swift
            .overlay(alignment: .topTrailing) {
                if settings.continuousListeningEnabled {
                    Circle()
                        .fill(continuousDotColor)
                        .frame(width: 10, height: 10)
                        .offset(x: 2, y: -2)
                }
            }
```

Add the computed color property at the bottom of the struct:

```swift
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

- [ ] **Step 3: Pass the engine to MicButton from ActiveTerminalView**

Find the `MicButton(...)` call in `ActiveTerminalView.swift` and add the parameter:

```swift
            MicButton(
                engine: speechEngine,
                settings: settings,
                coordinator: coordinator,
                continuousEngine: continuousEngine
            )
```

- [ ] **Step 4: Build and run on device/simulator**

Open `ClaudeRelay.xcodeproj` in Xcode. Cmd+B. Expected: clean build.

Run the app. Toggle "Continuous Listening" in settings (added in Task 17 below). Expected: a gray/green dot appears on the mic button when enabled.

- [ ] **Step 5: Commit**

```bash
git add ClaudeRelayApp/Views/ActiveTerminalView.swift ClaudeRelayApp/Views/Components/MicButton.swift
git commit -m "feat(ios): wire ContinuousListeningEngine into ActiveTerminalView + MicButton indicator"
```

---

## Task 17: iOS — expose the toggle in SettingsView

**Files:**
- Modify: `ClaudeRelayApp/Views/SettingsView.swift`

- [ ] **Step 1: Locate the speech settings section**

Open `ClaudeRelayApp/Views/SettingsView.swift`. Find the section with `smartCleanupEnabled` / `promptEnhancementEnabled` toggles.

- [ ] **Step 2: Add the continuous listening toggle and timeout slider**

Insert after the `promptEnhancementEnabled` toggle (inside the same `Section`):

```swift
                Toggle("Continuous Listening", isOn: $settings.continuousListeningEnabled)

                if settings.continuousListeningEnabled {
                    HStack {
                        Text("Wake Word")
                        Spacer()
                        Text(settings.wakeWord.capitalized).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Silence Timeout")
                            Spacer()
                            Text("\(settings.turnEndSilenceTimeout, specifier: "%.1f") s")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.turnEndSilenceTimeout,
                            in: 0.5...3.0,
                            step: 0.1
                        )
                    }
                }
```

- [ ] **Step 3: Build and verify in Xcode**

Cmd+B. Run the app. Expected: Settings > Speech section shows the new toggle. Enabling it reveals the wake-word readout and timeout slider.

- [ ] **Step 4: Commit**

```bash
git add ClaudeRelayApp/Views/SettingsView.swift
git commit -m "feat(ios): expose continuous listening toggle in SettingsView"
```

---

## Task 18: macOS — mirror the integration in MainWindow

**Files:**
- Modify: `ClaudeRelayMac/Views/MainWindow.swift`
- Modify: `ClaudeRelayMac/Models/AppSettings.swift` (if it's a separate file)
- Modify: `ClaudeRelayMac/Views/SettingsView.swift` (if separate)

> **Context:** macOS app has the same feature parity requirement. Apply the same StateObject + .task + MicButton wiring as on iOS.

- [ ] **Step 1: Mirror AppSettings keys on macOS**

If `ClaudeRelayMac` has its own `AppSettings`, add the same three `@AppStorage` keys as in Task 11:

```swift
    @AppStorage("continuousListeningEnabled") var continuousListeningEnabled = false
    @AppStorage("wakeWord") var wakeWord: String = "claude"
    @AppStorage("turnEndSilenceTimeout") var turnEndSilenceTimeout: Double = 1.5
```

- [ ] **Step 2: Locate the Mac speech engine StateObject**

Open `ClaudeRelayMac/Views/MainWindow.swift`. Find where `speechEngine` (the push-to-talk `OnDeviceSpeechEngine`) is declared.

- [ ] **Step 3: Add the continuous engine**

Add next to the existing engine:

```swift
    @StateObject private var continuousEngine = ContinuousListeningEngine.makeDefault()
```

- [ ] **Step 4: Add enable/disable wiring**

If the Mac app uses `scenePhase`, mirror the iOS `.task(id: continuousTaskID)`. Otherwise trigger only on the settings toggle:

```swift
        .task(id: settings.continuousListeningEnabled) {
            continuousEngine.onUtteranceReady = { text in
                guard let id = coordinator.activeSessionId,
                      let vm = coordinator.viewModel(for: id) else { return }
                vm.sendInput(text)
            }
            if settings.continuousListeningEnabled {
                await continuousEngine.enable()
            } else {
                await continuousEngine.disable()
            }
        }
```

- [ ] **Step 5: Update macOS MicButton**

If `ClaudeRelayMac` has its own `MicButton` file, apply the same `@ObservedObject var continuousEngine` parameter, overlay dot, and `continuousDotColor` computed property as in Task 16, Step 2. If the Mac target reuses the iOS `MicButton` via ClaudeRelayClient, just pass the engine through where the button is instantiated.

- [ ] **Step 6: Add the settings toggle on macOS**

If the Mac app has a separate `SettingsView`, add the same toggle block as in Task 17, Step 2.

- [ ] **Step 7: Build the Mac target**

Open `ClaudeRelay.xcodeproj`, select the `ClaudeRelayMac` scheme, Cmd+B. Expected: clean build. Run. Toggle Continuous Listening in settings. Expected: indicator visible.

- [ ] **Step 8: Commit**

```bash
git add ClaudeRelayMac
git commit -m "feat(mac): wire ContinuousListeningEngine into MainWindow"
```

---

## Task 19: Integration — manual verification checklist

> **Context:** Final end-to-end smoke test. Document expected behavior for the follow-up PR description.

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: all tests pass (including the new `ClaudeRelaySpeechTests` suite).

- [ ] **Step 2: Manual test on macOS**

1. Build and run the Mac app.
2. Open Settings → Speech → enable "Continuous Listening".
3. Connect to a server / open a session.
4. Verify the mic button shows a green dot.
5. Say "Claude, list files in my home directory".
6. Verify:
   - Dot turns blue briefly (wake-word check)
   - Dot turns red during speech
   - Dot turns yellow after you stop talking
   - Cleaned text appears in the terminal within a few seconds
   - Dot returns to green
7. Say something not starting with "Claude" — verify no output is produced.
8. Toggle Continuous Listening off — verify dot disappears and mic is released (no recording indicator in Control Center).

- [ ] **Step 3: Manual test on iOS**

Repeat step 2 on an iOS device. Additional checks:
- Background the app → mic indicator stops, orange indicator goes away.
- Foreground the app → continuous listening resumes.
- Receive a phone call → listening pauses; after call ends, resumes.

- [ ] **Step 4: Record findings**

If you need to capture notes (e.g., device-specific behavior), create an empty commit with the summary:

```bash
git commit --allow-empty -m "chore(speech): continuous voice input integration verified"
```

---

## Task 20: Update CLAUDE.md with the new pipeline

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add a new section to the Speech Layer docs**

Open `CLAUDE.md`. Find the "### Speech Layer Concurrency" section. After it, add:

```markdown
### Continuous Listening Pipeline

`ContinuousListeningEngine` is a parallel orchestrator to `OnDeviceSpeechEngine`
that powers always-on listening with a wake word ("Claude" by default).

Pipeline:
1. `StreamingAudioSource` (AVAudioEngine tap) → 30 ms @ 16 kHz mono Float32 chunks
2. `StreamingAudioBuffer` (10 s ring buffer, lock-protected) — zero-copy append
3. `VoiceActivityDetecting` — `SileroVoiceActivityDetector` (CoreML) when bundled,
   else `VoiceActivityDetector` (RMS energy + hysteresis)
4. On VAD `speechStart` → `WakeWordDetector` accumulates ≤ 3 s, runs WhisperKit,
   fuzzy-matches the keyword (Levenshtein ≤ 1)
5. If matched → `.recording`; VAD `silenceStart` triggers `TurnEndDetecting`
6. `SmartTurnTurnEndDetector` (CoreML, 8 s context) or `HeuristicTurnEndDetector`
   (always "done") predicts whether the speaker finished
7. On `.speakerDone` → `WhisperTranscriber` → `TextCleaner` → deliver via
   `onUtteranceReady` → `SessionCoordinator.vm.sendInput(text)`

`ContinuousListeningEngine.makeDefault()` picks the best available detectors
and falls back cleanly when CoreML models aren't bundled. Push-to-talk
(`OnDeviceSpeechEngine`) remains unchanged and coexists as the alternative
mode, selected by `AppSettings.continuousListeningEnabled`.

**Foreground-only:** audio engine is started/stopped on `scenePhase` changes
(iOS) or the settings toggle (macOS). No background audio entitlement is used.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document continuous listening pipeline in CLAUDE.md"
```

---

## Self-Review Notes

- All tasks produce a green test suite before commit.
- Each model-conversion task (12, 14) is marked deferrable — the pipeline has graceful fallbacks via `HeuristicTurnEndDetector` and the energy-based `VoiceActivityDetector`.
- The push-to-talk path (`OnDeviceSpeechEngine`) is never touched; regression risk is confined to the new code.
- UI integration (Tasks 16–18) is platform-specific but uses the same `makeDefault` factory.
- Types introduced early (e.g., `TurnEndDetecting.predict(utteranceAudio:)`) are consistent across mocks, real implementations, and call sites.

## Deferred Items

These can be tackled after the initial feature lands:

- Background audio on iOS (requires the `audio` background mode entitlement — out of scope per the approved design).
- Long-press mic button gesture to toggle modes in-place (settings toggle covers the v1 need).
- `AVAudioSession` interruption handling (phone calls / Siri) — basic case works because iOS pauses our audio; a polish pass should explicitly resume after `.interruptionEnded`.
- CoreML batch-inference optimization for Smart-Turn if prediction > 50 ms on older devices.
