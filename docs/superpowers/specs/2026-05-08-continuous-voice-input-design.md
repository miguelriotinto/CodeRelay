# Continuous Voice Input with Wake-Word and Speech-End Detection

> **Superseded (2026-09-14):** on-device voice transcription was removed from the iOS and macOS apps by `docs/superpowers/specs/2026-09-13-server-prompt-optimizer-design.md`. Kept for history only.

**Date**: 2026-05-08  
**Status**: Approved  
**Platforms**: macOS + iOS (foreground-only)

## Overview

Replace push-to-talk with an always-on microphone listening mode. When the user says "Claude", recording begins automatically. Speech-end is detected via a two-stage system (Silero VAD silence detection + Smart-Turn classifier), after which the utterance is transcribed, cleaned, and output to the active terminal session.

The existing push-to-talk mode (`OnDeviceSpeechEngine`) remains untouched and coexists as a user-selectable alternative.

## Architecture

Layered pipeline approach — new components alongside existing ones in `ClaudeRelaySpeech`:

| Component | Responsibility |
|-----------|---------------|
| `StreamingAudioBuffer` | Fixed-capacity ring buffer (10s / 640KB) for zero-copy audio sharing |
| `VoiceActivityDetector` | Wraps CoreML-converted Silero VAD, classifies 30ms chunks |
| `WakeWordDetector` | Accumulates speech, runs short WhisperKit, fuzzy-matches "Claude" |
| `TurnEndDetector` | VAD silence trigger + Smart-Turn CoreML classifier for endpoint prediction |
| `ContinuousListeningEngine` | Orchestrator: owns AVAudioEngine, routes audio, manages state machine |

## State Machine

```
.idle → .listening → .detectingWakeWord → .recording → .detectingTurnEnd → .transcribing → .cleaning → .outputting → .listening
```

Transitions:
- `.idle` → `.listening`: User enables continuous mode
- `.listening` → `.detectingWakeWord`: VAD detects speech start
- `.detectingWakeWord` → `.listening`: No wake-word in 3s window
- `.detectingWakeWord` → `.recording`: "Claude" detected (fuzzy match)
- `.recording` → `.detectingTurnEnd`: VAD detects 0.8s silence
- `.detectingTurnEnd` → `.recording`: Smart-Turn says "speaker continuing" (resume)
- `.detectingTurnEnd` → `.transcribing`: Smart-Turn says "speaker done" OR 3s hard timeout
- `.transcribing` → `.cleaning`: Transcription complete
- `.cleaning` → `.outputting`: Cleanup/enhancement complete
- `.outputting` → `.listening`: Text delivered to terminal
- Any state → `.idle`: User disables continuous mode

The mic stays open across all states. Audio flows continuously — only processing changes.

## Component Details

### StreamingAudioBuffer

```swift
public final class StreamingAudioBuffer: @unchecked Sendable {
    // Fixed 10s capacity (160,000 samples at 16kHz = ~640 KB)
    // os_unfair_lock for audio-thread-safe append
    // Zero-copy on the write path; read path returns copies for async processing
    
    func append(_ samples: [Float])              // audio thread
    func lastSeconds(_ duration: TimeInterval) -> [Float]  // consumer thread
    func audioSince(position: Int) -> [Float]    // utterance extraction
    var currentPosition: Int                     // mark utterance boundaries
}
```

### VoiceActivityDetector

```swift
@MainActor
public final class VoiceActivityDetector {
    struct Config {
        var speechThreshold: Float = 0.5
        var silenceThreshold: Float = 0.35    // hysteresis band
        var minSpeechDuration: TimeInterval = 0.25
        var minSilenceDuration: TimeInterval = 0.3
    }
    
    // Silero VAD is recurrent — maintains LSTM hidden state between chunks
    // Input: 480 samples (30ms at 16kHz)
    // Output: VADEvent (.speechStart, .speechContinue, .silenceStart, .silenceContinue)
    
    func process(chunk: [Float]) -> VADEvent
    func reset()  // clear hidden state (on mode transitions)
}
```

### WakeWordDetector

```swift
@MainActor
public final class WakeWordDetector {
    let keyword: String = "claude"
    let maxListenWindow: TimeInterval = 3.0
    
    // Accumulates audio while speech is active (max 3s)
    // Runs WhisperKit on accumulated audio
    // Fuzzy matches: "claude", "claud", "clawed", "cloud" (edit distance <= 1)
    // Returns audio offset so wake-word can be stripped from final transcription
    
    func feedAudio(_ samples: [Float])
    func checkForWakeWord() async -> WakeWordResult
    func reset()
}

enum WakeWordResult {
    case detected(audioSamplesAfterKeyword: Int)  // offset to strip
    case notDetected
    case timeout
}
```

### TurnEndDetector

```swift
@MainActor
public final class TurnEndDetector {
    struct Config {
        var silenceBeforeClassifier: TimeInterval = 0.8   // VAD silence triggers Smart-Turn
        var maxSilenceTimeout: TimeInterval = 3.0         // hard cutoff
        var smartTurnThreshold: Float = 0.5               // confidence for "done"
    }
    
    // Smart-Turn model: Whisper Tiny + linear classifier, int8, ~8MB CoreML
    // Input: up to 8s audio (128,000 samples), zero-padded from start if shorter
    // Output: probability [0.0-1.0] that speaker has finished
    
    func evaluate(utteranceAudio: [Float]) async -> TurnEndResult
}

enum TurnEndResult {
    case speakerDone(confidence: Float)
    case speakerContinuing(confidence: Float)
}
```

### ContinuousListeningEngine

```swift
@MainActor
public final class ContinuousListeningEngine: ObservableObject {
    @Published public private(set) var state: ContinuousListeningState = .idle
    
    // Owns AVAudioEngine with continuous 16kHz mono tap
    // Routes chunks to: StreamingAudioBuffer (always) + VoiceActivityDetector (always)
    // State-dependent routing to WakeWord / TurnEnd / Transcriber / Cleaner
    
    public func enable()    // start listening, request mic permission
    public func disable()   // stop engine, release mic
    public func forceStop() // manual stop during recording (tap override)
    
    public var onUtteranceReady: ((String) -> Void)?
    public var onStateChanged: ((ContinuousListeningState) -> Void)?
}
```

## Audio Routing

```
AVAudioEngine (16kHz mono tap, 30ms chunks)
    │
    ├──▶ StreamingAudioBuffer.append()     [always, audio thread]
    │
    └──▶ VoiceActivityDetector.process()   [always, dispatched to main]
              │
              └──▶ ContinuousListeningEngine (state transitions)
                        │
                        ├──▶ WakeWordDetector (when .detectingWakeWord)
                        ├──▶ TurnEndDetector (when .detectingTurnEnd)
                        ├──▶ WhisperTranscriber (when .transcribing)
                        └──▶ TextCleaner/CloudEnhancer (when .cleaning)
```

The hot path (per-chunk append + VAD) is allocation-free. Heavier inference (Whisper, Smart-Turn) reads buffer snapshots asynchronously.

## Model Integration

| Model | Format | Size | Delivery | Runs when |
|-------|--------|------|----------|-----------|
| Silero VAD | CoreML (converted from ONNX) | ~2 MB | App bundle | Every 30ms chunk (always) |
| Smart-Turn | CoreML (converted from ONNX int8) | ~8 MB | App bundle | During silence in `.recording` state |
| WhisperKit small.en | CoreML | ~500 MB | On-demand download (existing) | Wake-word check + full transcription |
| Qwen 0.8B GGUF | llama.cpp (Metal) | ~500 MB | On-demand download (existing) | Text cleanup phase |

CoreML conversion pipeline:
1. Silero VAD: `coremltools.convert(silero_vad.onnx)` — handle recurrent state tensors
2. Smart-Turn: `coremltools.convert(smart_turn_int8.onnx)` — static input shape [1, 128000]

## iOS Considerations

- **Foreground-only**: Audio engine starts/stops with `scenePhase`. No background audio entitlement.
- **Battery**: Silero VAD alone costs ~0.5% battery/hour. Whisper fires only during speech (~10% of active time).
- **Memory**: Ring buffer is fixed 640 KB. CoreML models use shared ANE/GPU memory.
- **Interruptions**: On phone call / Siri activation, gracefully pause via `AVAudioSession` interruption notification. Resume when interruption ends.

## macOS Considerations

- No `AVAudioSession` — mic permission via `NSMicrophoneUsageDescription` + `AVCaptureDevice.requestAccess`
- No battery concern (desktop/plugged in)
- Sleep/wake: pause on `NSWorkspace.willSleepNotification`, resume on wake (existing `SleepWakeObserver` pattern)

## UI Changes

### Mic Button Modes

Long-press on mic button toggles between:
- **Push-to-talk** (existing behavior, `OnDeviceSpeechEngine`)
- **Continuous listening** (new, `ContinuousListeningEngine`)

### Visual Indicators (Continuous Mode)

| State | Indicator |
|-------|-----------|
| `.listening` | Green pulsing dot (ambient, passive) |
| `.detectingWakeWord` | Blue dot (speech detected, checking) |
| `.recording` | Red dot + recording animation (capturing) |
| `.detectingTurnEnd` | Red → Yellow transition (checking if done) |
| `.transcribing` | Yellow dot (processing) |
| `.cleaning` | Sparkle icon (enhancing) |

### Settings

New `@AppStorage` keys:
- `continuousListeningEnabled: Bool` (default: `false`)
- `wakeWord: String` (default: `"claude"`)
- `turnEndSilenceTimeout: Double` (default: `1.5` seconds — this is the user-facing "how long to wait after you stop talking". Maps to `TurnEndDetector.Config.maxSilenceTimeout`. The internal `silenceBeforeClassifier` (0.8s) is not user-configurable.)

## Integration Points

### Output Path

Same as existing push-to-talk:
```
ContinuousListeningEngine.onUtteranceReady → coordinator.activeSessionId → vm.sendInput(text)
```

No changes to `SharedSessionCoordinator` or `TerminalViewModel`.

### Protocol Conformance

New protocols for testability:
- `protocol VoiceActivityDetecting: Sendable` — `func process(chunk:) -> VADEvent`
- `protocol TurnEndDetecting: Sendable` — `func evaluate(utteranceAudio:) async -> TurnEndResult`

### File Structure

New files in `Sources/ClaudeRelaySpeech/`:
- `StreamingAudioBuffer.swift`
- `VoiceActivityDetector.swift`
- `WakeWordDetector.swift`
- `TurnEndDetector.swift`
- `ContinuousListeningEngine.swift`
- `ContinuousListeningState.swift`
- `Models/SileroVAD.mlpackage` (in bundle)
- `Models/SmartTurn.mlpackage` (in bundle)

New files in app targets:
- `MicButton` updated with long-press + mode toggle + continuous indicators
- Settings view updated with new toggles

## Testing Strategy

- `VoiceActivityDetectorTests` — unit tests with known speech/silence audio fixtures
- `WakeWordDetectorTests` — mock transcriber, test fuzzy matching logic
- `TurnEndDetectorTests` — mock classifier, test timeout and threshold behavior
- `ContinuousListeningEngineTests` — integration tests with mock VAD/WakeWord/TurnEnd, verify state transitions
- `StreamingAudioBufferTests` — concurrent append/read correctness, capacity bounds

## Open Questions (None)

All decisions are finalized. Design is ready for implementation planning.
