# On-Device Speech Engine — Design Spec

> **Superseded (2026-09-14):** on-device voice transcription was removed from the iOS and macOS apps by `docs/superpowers/specs/2026-09-13-server-prompt-optimizer-design.md`. Kept for history only.

**Date:** 2026-04-10
**Status:** Approved
**Scope:** iOS only

## Overview

Replace SFSpeechRecognizer-based voice input with a fully on-device speech pipeline using WhisperKit (CoreML/ANE) for transcription and LLM.swift (Metal) for text cleanup. All processing happens on-device — no cloud dependency, full privacy.

## Decisions

| Aspect | Decision |
|--------|----------|
| Platform | iOS only |
| Interaction mode | Record-then-transcribe (tap to record, tap to process) |
| Speech model | Whisper small.en (~466 MB) via WhisperKit 0.18.0 + CoreML/ANE |
| Text cleanup | Qwen 3.5 0.8B Q4_K_M (~535 MB) via LLM.swift + Metal |
| Module location | `ClaudeRelayApp/Speech/` — 6 new files, iOS target only |
| UI | Same mic button, color per phase (red/yellow/green), haptic transitions |
| Model management | First-use download prompt (~1 GB total), no settings screen |
| Fallback | Keep existing `SpeechRecognizer` renamed to `LegacySpeechRecognizer` |
| Error strategy | LLM cleanup failure falls back to raw Whisper output |
| Memory | Whisper stays loaded; LLM loads on-demand, unloads after 30s idle |
| Testing | Protocol injection for mocks, no real models in CI |

## Architecture

### Module Layout

```
ClaudeRelayApp/
  ViewModels/
    LegacySpeechRecognizer.swift    (renamed from SpeechRecognizer.swift)
  Speech/
    OnDeviceSpeechEngine.swift      Pipeline orchestrator
    AudioCaptureSession.swift       AVAudioEngine → [Float] buffer
    WhisperTranscriber.swift        WhisperKit model load + transcribe
    TextCleaner.swift               LLM.swift GGUF load + clean
    SpeechModelStore.swift          Download, cache, delete models
    SpeechEngineState.swift         State enum
```

### Dependency Graph

```
ActiveTerminalView
    └── OnDeviceSpeechEngine (@StateObject)
            ├── AudioCaptureSession       (AVAudioEngine, no framework dep)
            ├── WhisperTranscriber         (imports WhisperKit)
            ├── TextCleaner                (imports LLM)
            └── SpeechModelStore           (Foundation, FileManager)
```

### SPM Dependencies

Added to `project.yml`:

- `WhisperKit` ~> 0.18.0 — Whisper speech-to-text via CoreML
- `LLM.swift` from `github.com/obra/LLM.swift` — GGUF inference via llama.cpp Metal backend

These are added to the iOS app target only, not to ClaudeRelayKit/Server/CLI.

## Pipeline

Sequential stages. User experience: hold button (red) → release → processing (yellow) → done (green haptic) → text in terminal.

```
Recording → Transcribing → Cleaning → Inserting
(AVAudioEngine)  (WhisperKit)   (LLM.swift)  (sendInput)
   ~Ns            ~1-2s           ~1-3s        instant
   red             yellow          yellow       green
```

### Detailed Flow

1. **User taps mic button** → `engine.startRecording()`
   - State → `.recording`
   - `AudioCaptureSession` starts AVAudioEngine, installs tap, accumulates `[Float]` at 16kHz mono
   - Button turns red, haptic `.impactMedium`

2. **User taps mic button again** → `engine.stopAndProcess()`
   - `AudioCaptureSession.stop()` returns `[Float]` buffer
   - State → `.transcribing`, button turns yellow

3. **Transcription** — `WhisperTranscriber.transcribe(audioBuffer:)`
   - WhisperKit runs Whisper small.en via CoreML on ANE/GPU
   - Returns raw transcription `String`
   - State → `.cleaning`

4. **Cleanup** — `TextCleaner.clean(text:)`
   - LLM.swift runs Qwen 3.5 0.8B Q4_K_M via Metal
   - Prompt: strip filler words, fix punctuation, correct errors
   - Returns cleaned `String`

5. **Insertion** — callback to TerminalViewModel
   - Cleaned text → UTF-8 Data via `vm.sendInput(text)` (String variant)
   - No newline appended — user may want to edit before hitting enter
   - State → `.idle`, haptic `.notificationSuccess`

### Audio Format

WhisperKit expects 16kHz mono Float32. `AudioCaptureSession` captures at hardware sample rate and uses AVAudioConverter to downsample.

### Model Storage

Models are stored in `<AppSupportDir>/Models/`:
- `<AppSupportDir>/Models/whisper-small.en/` — WhisperKit model files (.mlmodelc)
- `<AppSupportDir>/Models/qwen35-0.8b-q4km.gguf` — LLM cleanup model

WhisperKit handles its own download via `WhisperKit.download(variant:)`. The LLM GGUF is downloaded from HuggingFace via URLSession with resume support. Both are excluded from iCloud backup via `URLResourceValues.isExcludedFromBackup`.

### Memory Management

- Whisper model loaded on first use, kept in memory (primary model)
- LLM model loaded on-demand per cleanup call, unloaded after 30s idle via `Task.sleep` timer
- On `UIApplication.didReceiveMemoryWarningNotification`: unload LLM immediately
- Both models loaded simultaneously: ~1 GB RAM

## Component APIs

### SpeechEngineState

```swift
enum SpeechEngineState: Equatable {
    case idle
    case recording
    case transcribing
    case cleaning
    case error(String)
}
```

### OnDeviceSpeechEngine

```swift
@MainActor
final class OnDeviceSpeechEngine: ObservableObject {
    @Published private(set) var state: SpeechEngineState = .idle
    @Published private(set) var modelsReady: Bool = false

    init(transcriber: SpeechTranscribing, cleaner: TextCleaning,
         capture: AudioCaptureSession, modelStore: SpeechModelStore)

    func prepareModels() async
    func startRecording() throws
    func stopAndProcess() async -> String?
    func cancel()
}
```

### AudioCaptureSession

```swift
final class AudioCaptureSession {
    func start() throws
    func stop() -> [Float]
    var isRecording: Bool { get }
}
```

### WhisperTranscriber

```swift
protocol SpeechTranscribing {
    func transcribe(_ audioBuffer: [Float]) async throws -> String
}

final class WhisperTranscriber: SpeechTranscribing {
    func loadModel(from path: URL) async throws
    func transcribe(_ audioBuffer: [Float]) async throws -> String
    func unload()
    var isLoaded: Bool { get }
}
```

### TextCleaner

```swift
protocol TextCleaning {
    func clean(_ text: String) async throws -> String
}

final class TextCleaner: TextCleaning {
    func loadModel(from path: URL) async throws
    func clean(_ text: String) async throws -> String
    func unload()
    var isLoaded: Bool { get }
}
```

### SpeechModelStore

```swift
final class SpeechModelStore: ObservableObject {
    static let shared = SpeechModelStore()

    @Published private(set) var whisperDownloaded: Bool
    @Published private(set) var llmDownloaded: Bool
    @Published private(set) var downloadProgress: Double?

    var whisperModelPath: URL? { get }
    var llmModelPath: URL? { get }

    func downloadWhisperModel() async throws
    func downloadLLMModel() async throws
    func deleteModels()
    var totalModelSize: Int64 { get }
}
```

## UI Changes

### Mic Button States

| State | Color | Icon | Haptic |
|-------|-------|------|--------|
| `.idle` | gray (0.5 opacity) | `mic` | — |
| `.recording` | red (0.8 opacity) | `mic.fill` | `.impactMedium` |
| `.transcribing` | yellow (0.8) | `waveform` | — |
| `.cleaning` | yellow (0.8) | `sparkles` | — |
| `.error` | red flash → idle | `mic` | `.notificationError` |

### Button Action

- Tap while `.idle` → start recording
- Tap while `.recording` → stop and process
- Tap while `.transcribing`/`.cleaning` → cancel

### First-Use Model Download

When mic tapped and `modelsReady == false`:

1. Alert: "Download Speech Models?" — "On-device voice recognition requires a one-time download (~1 GB). This enables offline, private speech-to-text."
2. Buttons: "Download" / "Cancel"
3. During download: mic button shows circular progress ring
4. When done: `modelsReady` flips true, button returns to normal

### Lifecycle

- Recording stops on session switch
- Recording stops on background
- Pipeline cancels on background
- Memory warning → unload LLM model

## Error Handling

| Error | Handling | User Feedback |
|-------|----------|---------------|
| Mic permission denied | Reuse existing PermissionError alert | Alert with "Open Settings" |
| Model download fails | Retry 3x with exponential backoff | Alert: "Download failed. Retry?" |
| Disk space insufficient | Check before download (~1.1 GB needed) | Alert: "Not enough storage." |
| Transcription fails | State → `.error`, return nil | Button red flash, haptic error |
| LLM cleanup fails | Return raw transcription | Haptic success (uncleaned text) |
| Memory warning | Unload LLM; if mid-cleanup, return raw text | Graceful degradation |
| App backgrounded | Cancel pipeline, discard buffer | None |
| Empty audio (<0.5s) | Return nil | Button returns to idle |

### Degradation Strategy

```
Full pipeline:    audio → Whisper → LLM cleanup → insert     (best quality)
Cleanup failure:  audio → Whisper → insert raw text           (still good)
Whisper failure:  error state, nothing inserted                (fail visible)
```

LLM cleanup is never a hard gate.

### Cancellation

`stopAndProcess()` is a single Task. `cancel()` triggers `Task.isCancelled` checks between each pipeline stage. No partial text is ever inserted.

## Testing

### Unit Tests

| Test | Verifies |
|------|----------|
| `AudioCaptureSessionTests` | Buffer accumulates; stop returns [Float]; 16kHz conversion correct |
| `WhisperTranscriberTests` | Returns string for test audio; unload sets isLoaded false; transcribe when unloaded throws |
| `TextCleanerTests` | Removes fillers; returns raw on failure; 30s idle unload |
| `SpeechModelStoreTests` | Paths correct; downloaded flags match disk; deleteModels removes files |
| `OnDeviceSpeechEngineTests` | State transitions; cancel returns nil; empty audio returns nil; cleanup fallback |
| `SpeechEngineStateTests` | Equatable conformance |

### Mock Injection

Protocol-based: `SpeechTranscribing` and `TextCleaning` protocols allow injecting mocks that return canned strings or throw errors. No real models in CI.

### Integration Test

Manual on physical device before release: download models → record 5s → verify cleaned output.

## Inspiration from Ghost Pepper

Patterns adopted from ghost-pepper (MIT, github.com/matthartman/ghost-pepper):

- **Pipeline orchestrator pattern** — Ghost Pepper's `AppState` coordinates record→transcribe→clean→paste; our `OnDeviceSpeechEngine` does the same
- **Model lifecycle management** — Ghost Pepper's `ModelManager` handles download/load/unload; our `SpeechModelStore` + individual model wrappers follow the same pattern
- **LLM cleanup prompt strategy** — Ghost Pepper's `CleanupPromptBuilder` instructs the LLM to strip fillers and fix punctuation; we adopt the same prompt design
- **Graceful degradation** — Ghost Pepper's `TextCleaner` returns raw text on LLM failure; we do the same
- **Serialized transcription** — One transcription at a time, no concurrent model access
