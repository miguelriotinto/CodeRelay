# Continuous Voice Input v2 — ML Models, Unified Post-Processing, UX Polish

> **Superseded (2026-09-14):** on-device voice transcription was removed from the iOS and macOS apps by `docs/superpowers/specs/2026-09-13-server-prompt-optimizer-design.md`. Kept for history only.

**Date**: 2026-05-08
**Status**: Approved
**Platforms**: macOS + iOS (foreground-only)
**Predecessor**: [v1 design](2026-05-08-continuous-voice-input-design.md) and [v1 plan](../plans/2026-05-08-continuous-voice-input.md)

## Overview

v1 shipped a working continuous-listening pipeline with fallback detectors and local text cleanup. This v2 closes the functional gaps:

1. **Unified post-processing** — both push-to-talk and continuous modes honor `smartCleanupEnabled` and `promptEnhancementEnabled`, identically.
2. **Real ML-based turn-end detection** — Silero VAD + pipecat Smart-Turn classifier, both bundled as CoreML models.
3. **Dynamic settings** — users can change wake word, cleanup flags, and timeout without restarting the app.
4. **Mode interaction** — when continuous listening is ON, the mic button becomes a continuous-mode control; long-press provides temporary push-to-talk.
5. **Platform robustness** — iOS call/Siri interruption handling, macOS sleep/wake integration.

Scope is strictly additive. The existing `OnDeviceSpeechEngine`, `ContinuousListeningEngine`, and `AppSettings` surface area stays backward-compatible for anything the views or tests already depend on.

## Non-goals

- iOS background audio entitlement (explicitly out of scope per v1 design)
- User-editable wake word (stays read-only in UI; back-end accepts the value but UI remains a display-only "Claude")
- Custom ML model selection (Silero + Smart-Turn are hard-coded)

## Architecture

```
                                   ┌────────────────────────────────────┐
                                   │  AppSettings (iOS) / AppSettings   │
                                   │  (macOS) — shared @AppStorage keys │
                                   └──────────────┬─────────────────────┘
                                                  │
                           ┌─────── SpeechProcessingOptions ────────┐
                           │  (Equatable, Sendable value type)      │
                           └──────────────┬─────────────────────────┘
                                          │ pushed by .task(id:)
                                          ▼
  ┌──────────────────────────────┐    ┌────────────────────────────────┐
  │  OnDeviceSpeechEngine (PTT)  │    │  ContinuousListeningEngine     │
  │  - stopAndProcess()          │    │  - ingest() / enable() / …     │
  │  - calls SpeechPostProcessor │    │  - calls SpeechPostProcessor   │
  └──────────────┬───────────────┘    └──────────────┬─────────────────┘
                 │                                   │
                 └──────────────┬────────────────────┘
                                ▼
                 ┌──────────────────────────────┐
                 │  SpeechPostProcessor         │
                 │  - TextCleaner (local LLM)   │
                 │  - CloudPromptEnhancer (Haiku)│
                 │  - Single branching ruleset  │
                 └──────────────────────────────┘
```

Continuous engine additions:
```
StreamingAudioSource → StreamingAudioBuffer
                             │
                             ▼
                 SileroVoiceActivityDetector (CoreML, stateful)
                             │ VADEvent
                             ▼
         ContinuousListeningEngine state machine
                             │
                      silence detected in .recording
                             ▼
                    SmartTurnTurnEndDetector (CoreML, 8s context)
                             │
                   speakerDone  OR  turnEndSilenceTimeout fires
                             ▼
                    SpeechPostProcessor → onUtteranceReady
```

## Section 1 — Unified post-processing

### 1.1 New shared types in `ClaudeRelaySpeech`

```swift
public struct SpeechProcessingOptions: Equatable, Sendable {
    public var smartCleanupEnabled: Bool
    public var promptEnhancementEnabled: Bool
    public var bedrockBearerToken: String
    public var bedrockRegion: String

    // Continuous-only fields (PTT ignores these)
    public var wakeWord: String
    public var turnEndSilenceTimeout: TimeInterval

    public init(
        smartCleanupEnabled: Bool = true,
        promptEnhancementEnabled: Bool = false,
        bedrockBearerToken: String = "",
        bedrockRegion: String = "us-east-1",
        wakeWord: String = "claude",
        turnEndSilenceTimeout: TimeInterval = 1.5
    )
}

@MainActor
public final class SpeechPostProcessor {
    public init(cleaner: any TextCleaning, enhancer: CloudPromptEnhancer)

    /// Apply cleanup or enhancement per options. Never throws — on failure
    /// returns the input unchanged. Only ever returns empty string if input
    /// was empty.
    public func process(
        _ rawText: String,
        options: SpeechProcessingOptions
    ) async -> ProcessedText
}

public enum ProcessedText: Equatable, Sendable {
    case passthrough(String)             // no processing requested
    case cleaned(String)                 // local LLM cleanup applied
    case enhanced(String)                // Bedrock Haiku applied
    case refused(original: String)       // Haiku refused — deliver nothing
    case empty                            // input was empty / silence hallucination
}
```

The `ProcessedText` enum captures the distinctions that already live implicitly inside `OnDeviceSpeechEngine.stopAndProcess`. The caller decides whether `.refused` and `.empty` result in a delivered utterance (they don't — they produce nothing, same as today's push-to-talk behavior).

### 1.2 Engine integration

**`OnDeviceSpeechEngine`** loses its inline branch logic. `stopAndProcess` becomes:

```swift
public func stopAndProcess(options: SpeechProcessingOptions) async -> String? {
    // … existing state guards …
    // … transcribe as today …
    let processed = await postProcessor.process(rawText, options: options)
    switch processed {
    case .passthrough(let t), .cleaned(let t), .enhanced(let t): return t
    case .refused, .empty: return nil
    }
}
```

The old signature (`smartCleanup:promptEnhancement:bearerToken:region:`) gets a deprecation shim that packages args into `SpeechProcessingOptions` — keeps existing tests passing until they can be updated.

**`ContinuousListeningEngine`** gains:

```swift
public var options: SpeechProcessingOptions  // @MainActor-isolated

public func updateOptions(_ new: SpeechProcessingOptions)

// In runTranscription, replaces the direct cleaner call:
let processed = await postProcessor.process(rawText, options: currentOptions)
// Deliver same way as PTT.
```

`updateOptions(_:)` is the bridge for dynamic settings — views call it from their `.task(id: optionsHash)` modifier whenever any relevant `@AppStorage` key changes. When `wakeWord` changes, the engine rebuilds its `WakeWordDetector` in place (no teardown needed).

### 1.3 View-layer changes

Both `ActiveTerminalView` (iOS) and `WorkspaceView` (macOS):

```swift
private var optionsHash: String {
    "\(settings.smartCleanupEnabled)-\(settings.promptEnhancementEnabled)-\
(settings.wakeWord)-\(settings.turnEndSilenceTimeout)-\(settings.continuousListeningEnabled)\
-\(scenePhase)"  // iOS only on scenePhase
}

.task(id: optionsHash) {
    continuousEngine.updateOptions(currentOptionsFromSettings())
    if settings.continuousListeningEnabled && isActive {
        await continuousEngine.enable()
    } else {
        await continuousEngine.disable()
    }
}
```

`MicButton`'s push-to-talk tap uses the same `currentOptionsFromSettings()` helper to build its options struct. One source of truth per platform.

## Section 2 — ML-based turn-end detection

### 2.1 Model delivery

Both models ship **bundled in the app** (Silero VAD ~2MB, Smart-Turn ~8MB). Rationale:

- Always available offline, no download UX complexity
- Silero runs on every audio chunk — download-gated activation would be ugly
- Combined ~10MB is negligible on modern devices

Conversion artifacts live in `Sources/ClaudeRelaySpeech/Resources/`:
- `SileroVAD.mlpackage`
- `SmartTurn.mlpackage`

Python conversion scripts live in `tools/speech/` (for reproducibility, not runtime):
- `convert_silero_vad.py`
- `convert_smart_turn.py`

Both scripts produce deterministic output committed to the repo. CI doesn't need a Python toolchain.

### 2.2 SileroVoiceActivityDetector

```swift
@MainActor
public final class SileroVoiceActivityDetector: VoiceActivityDetecting {
    public init?(config: VoiceActivityDetector.Config = .init())
    // Returns nil if bundled model fails to load; caller falls back to energy VAD.

    public func process(chunk: [Float]) -> VADEvent
    public func reset()
}
```

Silero VAD is recurrent (internal LSTM state). Two valid integration paths:

1. **Stateful CoreML model** (iOS 17/macOS 14+) — convert with `ct.target.iOS17`, use CoreML state API. Preferred because it's ergonomic.
2. **Explicit state tensors** — pass `h`, `c` tensors as inputs and outputs each prediction. Fallback if stateful conversion fails.

Both deployment targets support stateful models. Conversion script tries stateful first; falls back to explicit state tensors if tracing fails.

**Composition with the base state machine**: Silero outputs a probability 0–1. The existing `VoiceActivityDetector` already has hysteresis + debouncing logic driven by a numeric "energy" signal. `SileroVoiceActivityDetector` wraps `VoiceActivityDetector` and feeds Silero's probability into it (amplified to match the 0.5/0.35 thresholds Silero is tuned for). Reuses proven debounce logic; only the scoring function changes.

### 2.3 SmartTurnTurnEndDetector

```swift
@MainActor
public final class SmartTurnTurnEndDetector: TurnEndDetecting {
    public init?(threshold: Float = 0.5)
    // Returns nil if bundled model fails to load.

    public func predict(utteranceAudio: [Float]) async -> TurnEndResult
}
```

Input: up to 8 seconds of 16kHz mono audio (128,000 samples). Samples > 8s are truncated from the start; samples < 8s are zero-padded at the start (Smart-Turn expects the newest audio at the end of its window).

Output: probability that the speaker has finished. `>= threshold` → `.speakerDone(confidence: p)`; otherwise `.speakerContinuing(confidence: 1-p)`.

Inference runs on ANE/GPU via CoreML — expected ~10–20ms on modern devices.

### 2.4 Hard silence timeout

Addresses v1 gap: if Smart-Turn repeatedly says "continuing" during a long pause, the engine currently never transitions to `.transcribing`.

In `runTurnEndCheck`:

```swift
private func runTurnEndCheck() {
    pendingTask = Task { [weak self] in
        guard let self else { return }
        let utterance = self.audioBuffer.audioSince(position: self.utteranceStartPosition)
        let timeoutSeconds = self.currentOptions.turnEndSilenceTimeout

        // Race the classifier against a hard timeout.
        let done: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let r = await self.turnEndDetector.predict(utteranceAudio: utterance)
                return r.isDone
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return true  // timeout = force done
            }
            for await first in group {
                group.cancelAll()
                return first
            }
            return true
        }

        guard !Task.isCancelled else { return }
        if done {
            self.runTranscription(utterance: utterance)
        } else {
            self.state = .recording
        }
    }
}
```

This is important: if the user paused mid-sentence and Smart-Turn correctly says "continuing", but then stays silent for `turnEndSilenceTimeout` seconds, the engine gives up waiting and transcribes what it has. Prevents stalls.

### 2.5 Updated makeDefault factory

```swift
public static func makeDefault(
    options: SpeechProcessingOptions = SpeechProcessingOptions()
) -> ContinuousListeningEngine {
    let vad: any VoiceActivityDetecting =
        SileroVoiceActivityDetector() ?? VoiceActivityDetector()
    let turnEnd: any TurnEndDetecting =
        SmartTurnTurnEndDetector() ?? HeuristicTurnEndDetector()
    // … construct other collaborators …
    let engine = ContinuousListeningEngine(/* … */)
    engine.updateOptions(options)
    return engine
}
```

Both `??` branches work today because v1 shipped both fallbacks. If model loading fails at runtime (e.g., CoreML compilation issue on a specific device), the engine transparently falls back to the baseline.

## Section 3 — Dynamic settings propagation

### 3.1 options flow

```
AppSettings (@AppStorage)
   ↓ @Published via ObservableObject
SwiftUI view body
   ↓ .task(id: optionsHash)
continuousEngine.updateOptions(new)  — @MainActor call
   ↓
Engine rebuilds WakeWordDetector if wakeWord changed
Engine stores new options for use in next runTurnEndCheck / runTranscription
```

The `.task(id:)` modifier re-fires whenever `optionsHash` changes. Because the hash includes every relevant settings key, any UI edit propagates within one SwiftUI tick.

`updateOptions` is idempotent — calling it with the same options is a no-op (cheap, uses `Equatable` check).

### 3.2 Mid-utterance changes

If the user changes `smartCleanupEnabled` while the engine is in `.transcribing` state, the change takes effect on the *next* utterance, not the in-flight one. Captured options are snapshotted into the `runTranscription` task at the moment it spawns.

## Section 4 — UX

### 4.1 Mic button behavior when continuous is enabled

| Gesture | Continuous OFF | Continuous ON |
|---|---|---|
| Single tap | Start/stop push-to-talk recording | Toggle continuous pause/resume |
| Long-press | (no-op) | Temporary push-to-talk while held |

Tap-to-toggle when continuous is on:
- If engine is `.idle`, tap calls `enable()` and updates a local `@State var continuousPausedByUser`
- If engine is not `.idle`, tap calls `disable()` and sets `continuousPausedByUser = true`
- Setting toggle OFF clears `continuousPausedByUser`

This lets the user quickly pause ambient listening (e.g., for a private conversation) without flipping the Settings switch.

Long-press for temporary PTT:
- Uses SwiftUI's `.simultaneousGesture(LongPressGesture(minimumDuration: 0.3))`
- On long-press begin: engine `disable()`, start PTT recording
- On long-press end: stop PTT recording, deliver text, re-enable continuous if settings allow
- The existing `OnDeviceSpeechEngine` handles the actual recording; the continuous engine is just paused

### 4.2 Visual indicator

The colored overlay dot on the mic button stays as implemented in v1. One state addition:

- `.paused` (new internal state on the view side, not a `ContinuousListeningState`) → dot is gray with a small "||" icon overlay

### 4.3 Settings UI

- `turnEndSilenceTimeout` slider now reads "Silence Timeout (max wait after speech)" with tooltip "How long the engine waits for turn-end prediction before giving up"
- Wake word readout remains read-only for v2 (display only)
- Add a footer explaining "Continuous listening uses on-device AI to detect when you've finished speaking."

## Section 5 — Platform robustness

### 5.1 iOS audio-session interruptions

`StreamingAudioSource` observes `AVAudioSession.interruptionNotification`:

```swift
private var interruptionObserver: NSObjectProtocol?

public func start() throws {
    // … existing setup …
    interruptionObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        queue: .main
    ) { [weak self] note in
        self?.handleInterruption(note)
    }
}

public func stop() {
    // … existing teardown …
    if let obs = interruptionObserver {
        NotificationCenter.default.removeObserver(obs)
        interruptionObserver = nil
    }
}

private func handleInterruption(_ note: Notification) {
    guard let userInfo = note.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
    switch type {
    case .began:
        // System paused us — tell the engine.
        onInterruption?(.began)
    case .ended:
        let shouldResume = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt)
            .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) }
            ?? false
        onInterruption?(.ended(shouldResume: shouldResume))
    @unknown default:
        break
    }
}

public var onInterruption: ((InterruptionEvent) -> Void)?

public enum InterruptionEvent {
    case began
    case ended(shouldResume: Bool)
}
```

`ContinuousListeningEngine` subscribes:

```swift
audioSource.onInterruption = { [weak self] event in
    Task { @MainActor [weak self] in
        guard let self else { return }
        switch event {
        case .began:
            self.pauseForInterruption()  // internal: mark paused, don't touch state
        case .ended(let shouldResume):
            if shouldResume {
                await self.enable()
            }
        }
    }
}
```

### 5.2 macOS sleep/wake

On macOS, hook the continuous engine into the existing `SleepWakeObserver` pattern (already used by `SharedSessionCoordinator`). On `willSleep`: `disable()`. On `didWake`: if settings allow, `enable()`.

Wire-up happens in `MainWindow` where the engine is instantiated. Same `.task(id:)` approach — adds a dependency on a `@State var` that the sleep/wake observer toggles.

## Section 6 — Test coverage additions

### 6.1 Unit tests

- `SpeechProcessingOptionsTests` — defaults, equality, hash stability
- `SpeechPostProcessorTests` — all 4 branches (passthrough / cleaned / enhanced / refused), plus empty input handling
- `SileroVoiceActivityDetectorTests` — model loads from bundle; probability output is sensible for silence vs tone; reset clears LSTM state
- `SmartTurnTurnEndDetectorTests` — model loads; pad/truncate logic is correct; threshold behavior

### 6.2 Integration tests

- `ContinuousListeningEngineTests.testOptionsChangeMidSessionTakesEffect`
- `ContinuousListeningEngineTests.testSmartTurnContinuingKeepsRecordingUntilHardTimeout` — uses a mock that always says "continuing", asserts transcription fires after `turnEndSilenceTimeout`
- `ContinuousListeningEngineTests.testCloudEnhancementPathDeliversEnhancedText`
- `OnDeviceSpeechEngineTests.testNewOptionsSignatureWorks` — verify the new `stopAndProcess(options:)` path

### 6.3 Regression tests

- Existing `OnDeviceSpeechEngineTests` must all pass with the deprecation shim
- Existing `ContinuousListeningEngineTests` must all pass after `updateOptions` is introduced (add it to `makeEngine` test helper)

## Section 7 — File structure

### New files

**`Sources/ClaudeRelaySpeech/`:**
- `SpeechProcessingOptions.swift` — options value type + hash helper
- `SpeechPostProcessor.swift` — unified cleanup/enhancement entry point
- `SileroVoiceActivityDetector.swift` — CoreML wrapper
- `SmartTurnTurnEndDetector.swift` — CoreML wrapper
- `Resources/SileroVAD.mlpackage` — bundled model artifact
- `Resources/SmartTurn.mlpackage` — bundled model artifact

**`tools/speech/`:**
- `convert_silero_vad.py` — conversion script
- `convert_smart_turn.py` — conversion script
- `README.md` — usage + prerequisite packages

**`Tests/ClaudeRelaySpeechTests/`:**
- `SpeechProcessingOptionsTests.swift`
- `SpeechPostProcessorTests.swift`
- `SileroVoiceActivityDetectorTests.swift`
- `SmartTurnTurnEndDetectorTests.swift`

### Modified files

- `Package.swift` — add new resources to `ClaudeRelaySpeech` target
- `Sources/ClaudeRelaySpeech/OnDeviceSpeechEngine.swift` — accept `SpeechProcessingOptions`, delegate to `SpeechPostProcessor`
- `Sources/ClaudeRelaySpeech/ContinuousListeningEngine.swift` — `updateOptions(_:)`, post-processor integration, hard timeout, dynamic wake word
- `Sources/ClaudeRelaySpeech/StreamingAudioSource.swift` — AVAudioSession interruption observer
- `ClaudeRelayApp/Views/ActiveTerminalView.swift` — updated options hash, pass options to both engines
- `ClaudeRelayApp/Views/Components/MicButton.swift` — tap-toggle when continuous enabled, long-press PTT
- `ClaudeRelayMac/Views/MainWindow.swift` / `WorkspaceView.swift` — same wire-up on macOS, sleep/wake hookup
- `ClaudeRelayMac/Views/SettingsView.swift` / `ClaudeRelayApp/Views/SettingsView.swift` — footer + tooltip refinements
- `CLAUDE.md` — update the Continuous Listening Pipeline section to reflect ML models and unified post-processing

## Backward compatibility

Every public API in `OnDeviceSpeechEngine` that ships today keeps working via a deprecation shim that forwards to the new options-taking version:

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

v1 tests and the existing MicButton call site keep working untouched. Tests get migrated to the new signature over the course of the implementation; once all call sites are updated, the shim can be removed in a later PR.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Silero CoreML conversion fails or produces wrong output shape | Keep energy-based VAD as fallback via `??` in `makeDefault`; conversion script validates output against a reference sample |
| Smart-Turn inference too slow on older devices | Check latency in integration tests; fall back to `HeuristicTurnEndDetector` if p50 > 100ms |
| iOS AVAudioSession interruption handling regresses existing push-to-talk | The observer lives in `StreamingAudioSource` only (continuous pipeline), not `AudioCaptureSession` (push-to-talk); PTT is untouched |
| Bundle size +10MB is noticed | App bundle size stays well under iOS's 200MB cellular-download limit; user-facing impact is negligible |
| Long-press gesture conflicts with existing iOS "preview" gesture | Use `.simultaneousGesture` so it composes with any ambient gesture; test on a real device |

## Rollout

This is a single feature branch (`feature/continuous-voice-v2`), cut from `main` after v1 merges. Internal phasing is cosmetic — the PR lands as one unit.

Manual verification steps (same as v1 Task 19, plus):
1. Change `smartCleanupEnabled` mid-session — next utterance should respect the new setting
2. Change `turnEndSilenceTimeout` to 0.5s — engine should deliver faster
3. During continuous listening, get a phone call on iOS — engine should pause and resume
4. Sleep Mac while continuous is enabled — engine should pause; on wake, resume
5. Say "Claude, list files" with prompt enhancement enabled — terminal receives the Haiku-rewritten prompt
6. Tap mic while continuous is on → verify pause; tap again → verify resume
7. Long-press mic while continuous is on → verify PTT recording starts; release → verify delivery + continuous re-engages
