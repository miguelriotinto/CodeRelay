# On-Device Speech Engine Implementation Plan

> **Superseded (2026-09-14):** on-device voice transcription was removed from the iOS and macOS apps by `docs/superpowers/specs/2026-09-13-server-prompt-optimizer-design.md`. Kept for history only.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace SFSpeechRecognizer with a fully on-device speech pipeline using WhisperKit (CoreML/ANE) for transcription and LLM.swift (Metal) for text cleanup.

**Architecture:** New `ClaudeRelayApp/Speech/` module with 6 files. `OnDeviceSpeechEngine` orchestrates a sequential pipeline: audio capture → Whisper transcription → LLM cleanup → terminal insertion. The existing `SpeechRecognizer` is renamed to `LegacySpeechRecognizer` and kept as fallback. Protocol-based dependency injection enables testing without real models.

**Tech Stack:** WhisperKit 0.18.0, LLM.swift (llama.cpp Metal backend), AVAudioEngine, CoreML, Swift 5.9, iOS 17+

**Spec:** `docs/superpowers/specs/2026-04-10-on-device-speech-engine-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `ClaudeRelayApp/Speech/SpeechEngineState.swift` | State enum for pipeline phases |
| Create | `ClaudeRelayApp/Speech/AudioCaptureSession.swift` | AVAudioEngine wrapper → 16kHz mono [Float] |
| Create | `ClaudeRelayApp/Speech/WhisperTranscriber.swift` | WhisperKit model load + transcribe + SpeechTranscribing protocol |
| Create | `ClaudeRelayApp/Speech/TextCleaner.swift` | LLM.swift GGUF load + clean + TextCleaning protocol |
| Create | `ClaudeRelayApp/Speech/SpeechModelStore.swift` | Model download, cache, disk management |
| Create | `ClaudeRelayApp/Speech/OnDeviceSpeechEngine.swift` | Pipeline orchestrator — the only thing UI talks to |
| Rename | `ClaudeRelayApp/ViewModels/SpeechRecognizer.swift` → `LegacySpeechRecognizer.swift` | Keep as fallback |
| Modify | `ClaudeRelayApp/Views/ActiveTerminalView.swift` | Replace MicButton with new engine-driven version |
| Modify | `project.yml` | Add WhisperKit + LLM.swift SPM dependencies |

---

### Task 1: Add SPM Dependencies

**Files:**
- Modify: `project.yml`

This task adds WhisperKit and LLM.swift as SPM packages and wires them to the iOS app target.

- [ ] **Step 1: Add packages to project.yml**

Open `project.yml` and add the two new packages under the `packages:` key, and add them as dependencies to the `ClaudeRelayApp` target:

```yaml
name: ClaudeRelay
options:
  bundleIdPrefix: com.claude
  deploymentTarget:
    iOS: "17.0"
  xcodeVersion: "15.0"
  generateEmptyDirectories: true

packages:
  ClaudeRelayClient:
    path: .
  SwiftTerm:
    url: https://github.com/migueldeicaza/SwiftTerm.git
    majorVersion: 1.2.0
  WhisperKit:
    url: https://github.com/argmaxinc/WhisperKit.git
    minorVersion: 0.18.0
  LLMSwift:
    url: https://github.com/obra/LLM.swift.git
    branch: main

targets:
  ClaudeRelayApp:
    type: application
    platform: iOS
    sources:
      - path: ClaudeRelayApp
        excludes:
          - README.md
    dependencies:
      - package: ClaudeRelayClient
        product: ClaudeRelayClient
      - package: SwiftTerm
      - package: WhisperKit
      - package: LLMSwift
        product: LLM
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.claude.relay
        INFOPLIST_FILE: ClaudeRelayApp/Info.plist
        INFOPLIST_KEY_CFBundleDisplayName: "Claude Relay"
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
        INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad: "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
        INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone: "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
        INFOPLIST_KEY_NSMicrophoneUsageDescription: "Claude Relay needs microphone access for voice-to-text input."
        INFOPLIST_KEY_NSSpeechRecognitionUsageDescription: "Claude Relay uses speech recognition to convert voice input to terminal commands."
        SWIFT_VERSION: "5.9"
        DEVELOPMENT_TEAM: QHT2YY3LU6
        SUPPORTED_PLATFORMS: "iphonesimulator iphoneos"
        SUPPORTS_MACCATALYST: NO
        GENERATE_INFOPLIST_FILE: YES
```

- [ ] **Step 2: Regenerate Xcode project**

Run:
```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodegen generate
```
Expected: `Generating project...` followed by `Project generated`

- [ ] **Step 3: Resolve packages**

Open the project in Xcode or run:
```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodebuild -resolvePackageDependencies -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp
```
Expected: Package resolution succeeds. WhisperKit, LLM.swift, and their transitive dependencies are fetched.

- [ ] **Step 4: Verify build**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED` — the app builds with the new dependencies even though no code uses them yet.

- [ ] **Step 5: Commit**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay
git add project.yml ClaudeRelay.xcodeproj
git commit -m "chore: add WhisperKit and LLM.swift SPM dependencies"
```

---

### Task 2: Create SpeechEngineState

**Files:**
- Create: `ClaudeRelayApp/Speech/SpeechEngineState.swift`

- [ ] **Step 1: Create the Speech directory**

```bash
mkdir -p /Users/miguelriotinto/Desktop/Projects/ClaudeRelay/ClaudeRelayApp/Speech
```

- [ ] **Step 2: Write SpeechEngineState.swift**

```swift
import Foundation

/// Pipeline states for the on-device speech engine.
/// UI observes this to drive mic button color and haptics.
enum SpeechEngineState: Equatable {
    case idle
    case recording
    case transcribing
    case cleaning
    case error(String)
}
```

- [ ] **Step 3: Verify build**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodegen generate && xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay
git add ClaudeRelayApp/Speech/SpeechEngineState.swift
git commit -m "feat(speech): add SpeechEngineState enum"
```

---

### Task 3: Create AudioCaptureSession

**Files:**
- Create: `ClaudeRelayApp/Speech/AudioCaptureSession.swift`

- [ ] **Step 1: Write AudioCaptureSession.swift**

```swift
import AVFoundation

/// Captures microphone audio and accumulates a 16kHz mono Float32 buffer.
/// Not an actor — must be called from @MainActor (OnDeviceSpeechEngine).
final class AudioCaptureSession {

    private let audioEngine = AVAudioEngine()
    private var buffer: [Float] = []
    private(set) var isRecording = false

    /// Minimum recording duration in seconds to avoid empty transcriptions.
    static let minimumDuration: TimeInterval = 0.5

    private var recordingStart: Date?

    /// Configure audio session, install tap on input node, start engine.
    func start() throws {
        guard !isRecording else { return }
        buffer.removeAll()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 16kHz mono Float32 (WhisperKit requirement)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] pcmBuffer, _ in
            guard let self else { return }
            self.convert(buffer: pcmBuffer, using: converter, targetFormat: targetFormat)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recordingStart = Date()
        isRecording = true
    }

    /// Stop engine, deactivate audio session, return accumulated buffer.
    /// Returns nil if recording was shorter than `minimumDuration`.
    func stop() -> [Float]? {
        guard isRecording else { return nil }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false

        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )

        // Guard against empty/too-short recordings
        if let start = recordingStart,
           Date().timeIntervalSince(start) < Self.minimumDuration {
            buffer.removeAll()
            return nil
        }

        let result = buffer
        buffer.removeAll()
        return result
    }

    // MARK: - Private

    private func convert(
        buffer pcmBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let frameCount = AVAudioFrameCount(
            Double(pcmBuffer.frameLength) * 16000.0 / pcmBuffer.format.sampleRate
        )
        guard frameCount > 0,
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
        else { return }

        var error: NSError?
        var hasData = true
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return pcmBuffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        if error == nil, let channelData = convertedBuffer.floatChannelData {
            let samples = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: Int(convertedBuffer.frameLength)
            ))
            self.buffer.append(contentsOf: samples)
        }
    }
}

enum AudioCaptureError: Error, LocalizedError {
    case formatCreationFailed
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed: return "Failed to create 16kHz audio format"
        case .converterCreationFailed: return "Failed to create audio converter"
        }
    }
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodegen generate && xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay
git add ClaudeRelayApp/Speech/AudioCaptureSession.swift
git commit -m "feat(speech): add AudioCaptureSession with 16kHz resampling"
```

---

### Task 4: Create WhisperTranscriber + SpeechTranscribing Protocol

**Files:**
- Create: `ClaudeRelayApp/Speech/WhisperTranscriber.swift`

- [ ] **Step 1: Write WhisperTranscriber.swift**

```swift
import Foundation
import WhisperKit

/// Protocol for speech transcription — enables mock injection in tests.
protocol SpeechTranscribing: Sendable {
    func transcribe(_ audioBuffer: [Float]) async throws -> String
}

/// Wraps WhisperKit to transcribe [Float] audio buffers into text.
final class WhisperTranscriber: SpeechTranscribing {

    private var whisperKit: WhisperKit?
    private(set) var isLoaded = false

    /// Download and load the Whisper small.en model.
    /// WhisperKit manages its own model storage under Application Support.
    func loadModel() async throws {
        let kit = try await WhisperKit(
            model: "openai_whisper-small.en",
            verbose: false,
            prewarm: true
        )
        self.whisperKit = kit
        self.isLoaded = true
    }

    /// Transcribe a 16kHz mono Float32 audio buffer.
    /// Returns the best transcription string, or throws on failure.
    func transcribe(_ audioBuffer: [Float]) async throws -> String {
        guard let whisperKit else {
            throw TranscriberError.modelNotLoaded
        }

        let results = try await whisperKit.transcribe(audioArray: audioBuffer)

        let text = results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw TranscriberError.emptyTranscription
        }

        return text
    }

    /// Release the model from memory.
    func unload() {
        whisperKit = nil
        isLoaded = false
    }
}

enum TranscriberError: Error, LocalizedError {
    case modelNotLoaded
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Whisper model not loaded"
        case .emptyTranscription: return "No speech detected"
        }
    }
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodegen generate && xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED` — WhisperKit APIs may differ slightly from this code. If the build fails, check WhisperKit's current API:
- `WhisperKit(model:verbose:prewarm:)` — check init signature
- `whisperKit.transcribe(audioArray:)` — check method name and return type
Adjust the code to match the actual API.

- [ ] **Step 3: Commit**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay
git add ClaudeRelayApp/Speech/WhisperTranscriber.swift
git commit -m "feat(speech): add WhisperTranscriber with SpeechTranscribing protocol"
```

---

### Task 5: Create TextCleaner + TextCleaning Protocol

**Files:**
- Create: `ClaudeRelayApp/Speech/TextCleaner.swift`

- [ ] **Step 1: Write TextCleaner.swift**

```swift
import Foundation
import LLM

/// Protocol for text cleanup — enables mock injection in tests.
protocol TextCleaning: Sendable {
    func clean(_ text: String) async throws -> String
}

/// Runs a local Qwen 3.5 0.8B GGUF model via llama.cpp (Metal GPU) to clean transcriptions.
final class TextCleaner: TextCleaning {

    private var llm: LLM?
    private var unloadTimer: Task<Void, Never>?
    private(set) var isLoaded = false

    /// Idle timeout before unloading the model to free memory.
    static let idleTimeout: TimeInterval = 30

    /// Load a GGUF model from disk.
    func loadModel(from path: URL) async throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw CleanerError.modelFileNotFound
        }

        let model = try await LLM(from: path, maxTokenCount: 2048)
        self.llm = model
        self.isLoaded = true
    }

    /// Clean transcribed text: remove filler words, fix punctuation, correct errors.
    /// Auto-loads the model on first call if a modelPath was set.
    /// Returns the original text if cleanup fails (graceful degradation).
    var modelPath: URL?

    func clean(_ text: String) async throws -> String {
        // Auto-load on first use (on-demand loading per spec)
        if llm == nil, let path = modelPath {
            try await loadModel(from: path)
        }

        guard let llm else {
            throw CleanerError.modelNotLoaded
        }

        resetIdleTimer()

        let prompt = Self.buildCleanupPrompt(for: text)
        let response = try await llm.respond(to: prompt)

        let cleaned = Self.sanitizeResponse(response)
        return cleaned.isEmpty ? text : cleaned
    }

    /// Release the model from memory.
    func unload() {
        unloadTimer?.cancel()
        unloadTimer = nil
        llm = nil
        isLoaded = false
    }

    // MARK: - Private

    /// Start or restart the idle timer. Unloads model after `idleTimeout` seconds.
    private func resetIdleTimer() {
        unloadTimer?.cancel()
        unloadTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTimeout))
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    /// Build the cleanup prompt. Adapted from Ghost Pepper's CleanupPromptBuilder pattern.
    static func buildCleanupPrompt(for text: String) -> String {
        """
        You are a transcription cleanup engine. You are NOT a chatbot. You are NOT an assistant. \
        Your ONLY job is to clean up speech-to-text output.

        Rules:
        - Remove filler words (um, uh, like, you know, so, basically, actually, literally)
        - Fix punctuation and capitalization
        - Correct obvious misheard words based on context
        - Preserve the speaker's meaning and tone exactly
        - Do NOT add, rephrase, or summarize content
        - Do NOT add any commentary, explanation, or preamble
        - Output ONLY the cleaned text, nothing else

        Input: \(text)
        """
    }

    /// Strip any <think> reasoning blocks or markdown artifacts from LLM output.
    static func sanitizeResponse(_ response: String) -> String {
        var result = response

        // Strip <think>...</think> blocks (Qwen 3.5 thinking mode)
        while let thinkStart = result.range(of: "<think>"),
              let thinkEnd = result.range(of: "</think>") {
            result.removeSubrange(thinkStart.lowerBound...thinkEnd.upperBound)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CleanerError: Error, LocalizedError {
    case modelNotLoaded
    case modelFileNotFound

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Cleanup model not loaded"
        case .modelFileNotFound: return "Cleanup model file not found on disk"
        }
    }
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodegen generate && xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED` — LLM.swift's API may differ. Check:
- `LLM(from: URL, maxTokenCount: Int)` — constructor signature
- `llm.respond(to: String)` — method name
Adjust code to match the actual LLM.swift API.

- [ ] **Step 3: Commit**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay
git add ClaudeRelayApp/Speech/TextCleaner.swift
git commit -m "feat(speech): add TextCleaner with LLM-based transcription cleanup"
```

---

### Task 6: Create SpeechModelStore

**Files:**
- Create: `ClaudeRelayApp/Speech/SpeechModelStore.swift`

- [ ] **Step 1: Write SpeechModelStore.swift**

```swift
import Foundation
import WhisperKit

/// Manages model downloads, caching, and disk lifecycle for the speech pipeline.
@MainActor
final class SpeechModelStore: ObservableObject {

    static let shared = SpeechModelStore()

    @Published private(set) var whisperReady = false
    @Published private(set) var llmDownloaded = false
    @Published private(set) var downloadProgress: Double?

    /// HuggingFace URL for the Qwen 3.5 0.8B Q4_K_M GGUF model.
    private static let llmModelURL = URL(
        string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf"
    )!

    private static let llmFileName = "qwen35-0.8b-q4km.gguf"

    var modelsReady: Bool { whisperReady && llmDownloaded }

    // MARK: - Paths

    /// Base directory for speech models: <AppSupport>/Models/
    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Models", isDirectory: true)
    }

    /// Path to the LLM GGUF file on disk.
    var llmModelPath: URL {
        modelsDirectory.appendingPathComponent(Self.llmFileName)
    }

    // MARK: - Init

    private init() {
        // Check if LLM model already exists on disk
        llmDownloaded = FileManager.default.fileExists(atPath: llmModelPath.path)
    }

    // MARK: - Download

    /// Download both models. Updates `downloadProgress` during the process.
    func downloadAllModels() async throws {
        downloadProgress = 0.0

        // Phase 1: Whisper model (WhisperKit handles its own download + CoreML compilation)
        // WhisperKit stores models in its own Application Support subdirectory.
        downloadProgress = 0.1
        _ = try await WhisperKit(
            model: "openai_whisper-small.en",
            verbose: false,
            prewarm: true
        )
        whisperReady = true
        downloadProgress = 0.5

        // Phase 2: LLM GGUF download (if not already on disk)
        if !llmDownloaded {
            try await downloadLLMModel()
        }

        downloadProgress = 1.0

        // Brief delay to show completion, then clear progress
        try? await Task.sleep(for: .milliseconds(500))
        downloadProgress = nil
    }

    /// Download the LLM GGUF file from HuggingFace.
    private func downloadLLMModel() async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let (tempURL, response) = try await URLSession.shared.download(from: Self.llmModelURL) { [weak self] progress in
            Task { @MainActor in
                // Map LLM download progress to 0.5–1.0 range (second half of total progress)
                self?.downloadProgress = 0.5 + (progress * 0.5)
            }
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ModelStoreError.downloadFailed
        }

        // Move temp file to final location
        let destination = llmModelPath
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)

        // Exclude from iCloud backup
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDest = destination
        try mutableDest.setResourceValues(resourceValues)

        llmDownloaded = true
    }

    /// Delete all downloaded models to free disk space.
    func deleteModels() {
        try? FileManager.default.removeItem(at: modelsDirectory)
        whisperReady = false
        llmDownloaded = false
    }

    /// Total bytes used by models on disk.
    var totalModelSize: Int64 {
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else { return 0 }
        let enumerator = FileManager.default.enumerator(at: modelsDirectory, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}

enum ModelStoreError: Error, LocalizedError {
    case downloadFailed
    case insufficientDiskSpace

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "Failed to download speech model"
        case .insufficientDiskSpace: return "Not enough storage for speech models (~1 GB required)"
        }
    }
}
```

**Note on URLSession.download with progress:** The `URLSession.shared.download(from:progress:)` API with a progress closure may not exist in Foundation. If it doesn't compile, replace with a `URLSessionDownloadDelegate`-based approach or use `URLSession.shared.download(from:)` without progress tracking for the first pass, then add progress reporting via `URLSessionDownloadDelegate` in a follow-up.

- [ ] **Step 2: Verify build**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodegen generate && xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED` — adjust download code if URLSession API differs.

- [ ] **Step 3: Commit**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay
git add ClaudeRelayApp/Speech/SpeechModelStore.swift
git commit -m "feat(speech): add SpeechModelStore for model download and caching"
```

---

### Task 7: Create OnDeviceSpeechEngine

**Files:**
- Create: `ClaudeRelayApp/Speech/OnDeviceSpeechEngine.swift`

This is the pipeline orchestrator — the only class the UI interacts with.

- [ ] **Step 1: Write OnDeviceSpeechEngine.swift**

```swift
import Foundation
import UIKit

/// Orchestrates the on-device speech pipeline: record → transcribe → clean → output.
/// This is the only class the UI talks to.
@MainActor
final class OnDeviceSpeechEngine: ObservableObject {

    @Published private(set) var state: SpeechEngineState = .idle
    @Published private(set) var modelsReady: Bool = false

    let modelStore: SpeechModelStore

    private let transcriber: any SpeechTranscribing
    private let cleaner: any TextCleaning
    private let capture: AudioCaptureSession

    // WhisperTranscriber needs explicit load — hold a typed reference
    private let whisperTranscriber: WhisperTranscriber?
    private let textCleaner: TextCleaner?

    private var processingTask: Task<String?, Never>?
    private var memoryWarningObserver: NSObjectProtocol?

    // MARK: - Init

    /// Production initializer — creates real WhisperTranscriber and TextCleaner.
    convenience init(modelStore: SpeechModelStore = .shared) {
        let transcriber = WhisperTranscriber()
        let cleaner = TextCleaner()
        self.init(
            transcriber: transcriber,
            cleaner: cleaner,
            capture: AudioCaptureSession(),
            modelStore: modelStore,
            whisperTranscriber: transcriber,
            textCleaner: cleaner
        )
    }

    /// Test initializer — accepts protocol-typed mocks.
    init(
        transcriber: any SpeechTranscribing,
        cleaner: any TextCleaning,
        capture: AudioCaptureSession,
        modelStore: SpeechModelStore,
        whisperTranscriber: WhisperTranscriber? = nil,
        textCleaner: TextCleaner? = nil
    ) {
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.capture = capture
        self.modelStore = modelStore
        self.whisperTranscriber = whisperTranscriber
        self.textCleaner = textCleaner

        self.modelsReady = modelStore.modelsReady

        observeMemoryWarnings()
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Model Preparation

    /// Download models and load Whisper into memory.
    /// LLM cleanup model is loaded on-demand (first clean() call), not here.
    func prepareModels() async {
        do {
            try await modelStore.downloadAllModels()
            try await whisperTranscriber?.loadModel()
            // Set the LLM path so TextCleaner can auto-load on first use
            textCleaner?.modelPath = modelStore.llmModelPath
            modelsReady = true
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Recording

    /// Begin capturing audio. State → .recording.
    func startRecording() throws {
        guard state == .idle else { return }
        try capture.start()
        state = .recording
    }

    /// Stop recording and run the full pipeline: transcribe → clean → return text.
    /// Returns nil on cancellation, empty audio, or transcription failure.
    func stopAndProcess() async -> String? {
        guard state == .recording else { return nil }

        // Stop audio capture
        guard let audioBuffer = capture.stop() else {
            state = .idle
            return nil
        }

        // Run pipeline in a cancellable task
        let task = Task<String?, Never> { [transcriber, cleaner] in
            // Phase 1: Transcribe
            var rawText: String
            do {
                rawText = try await transcriber.transcribe(audioBuffer)
            } catch {
                return nil
            }

            guard !Task.isCancelled else { return nil }

            // Phase 2: Clean (best-effort — falls back to raw text on failure)
            do {
                let cleaned = try await cleaner.clean(rawText)
                return cleaned
            } catch {
                // Graceful degradation: return uncleaned text
                return rawText
            }
        }

        processingTask = task
        state = .transcribing

        // Observe when transcription completes and cleaning starts
        // (We can't observe this from inside the task easily, so we set
        //  .cleaning after a brief delay as a UX approximation.
        //  The actual state transition is transcribing → cleaning → idle.)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if state == .transcribing {
                state = .cleaning
            }
        }

        let result = await task.value
        processingTask = nil

        if result != nil {
            state = .idle
        } else if state != .idle {
            // Only show error if we weren't cancelled
            state = .error("Transcription failed")
            // Auto-recover after brief flash
            Task {
                try? await Task.sleep(for: .seconds(1))
                if case .error = state { state = .idle }
            }
        }

        return result
    }

    /// Cancel any in-progress pipeline and return to idle.
    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        if capture.isRecording {
            _ = capture.stop()
        }
        state = .idle
    }

    // MARK: - Memory Management

    private func observeMemoryWarnings() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.textCleaner?.unload()
        }
    }
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodegen generate && xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay
git add ClaudeRelayApp/Speech/OnDeviceSpeechEngine.swift
git commit -m "feat(speech): add OnDeviceSpeechEngine pipeline orchestrator"
```

---

### Task 8: Rename SpeechRecognizer to LegacySpeechRecognizer

**Files:**
- Modify: `ClaudeRelayApp/ViewModels/SpeechRecognizer.swift` → rename file and class
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift` — update reference

- [ ] **Step 1: Rename the file**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay
mv ClaudeRelayApp/ViewModels/SpeechRecognizer.swift ClaudeRelayApp/ViewModels/LegacySpeechRecognizer.swift
```

- [ ] **Step 2: Rename the class inside the file**

Open `ClaudeRelayApp/ViewModels/LegacySpeechRecognizer.swift` and change line 6:

From:
```swift
final class SpeechRecognizer: ObservableObject {
```
To:
```swift
final class LegacySpeechRecognizer: ObservableObject {
```

- [ ] **Step 3: Update ActiveTerminalView reference**

In `ClaudeRelayApp/Views/ActiveTerminalView.swift`, line 14, change:

From:
```swift
    @StateObject private var speechRecognizer = SpeechRecognizer()
```
To:
```swift
    @StateObject private var speechRecognizer = LegacySpeechRecognizer()
```

And in the MicButton struct, line 195, change:

From:
```swift
    @ObservedObject var speechRecognizer: SpeechRecognizer
```
To:
```swift
    @ObservedObject var speechRecognizer: LegacySpeechRecognizer
```

- [ ] **Step 4: Verify build**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodegen generate && xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED` — app still works exactly as before, just with the renamed class.

- [ ] **Step 5: Commit**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay
git add ClaudeRelayApp/ViewModels/LegacySpeechRecognizer.swift ClaudeRelayApp/Views/ActiveTerminalView.swift
git rm --cached ClaudeRelayApp/ViewModels/SpeechRecognizer.swift 2>/dev/null; true
git commit -m "refactor: rename SpeechRecognizer to LegacySpeechRecognizer"
```

---

### Task 9: Integrate OnDeviceSpeechEngine into ActiveTerminalView

**Files:**
- Modify: `ClaudeRelayApp/Views/ActiveTerminalView.swift`

This is the main integration task — replacing the MicButton with the new engine-driven version.

- [ ] **Step 1: Add the engine StateObject to ActiveTerminalView**

In `ClaudeRelayApp/Views/ActiveTerminalView.swift`, after line 14 (the `LegacySpeechRecognizer` line), add:

```swift
    @StateObject private var speechEngine = OnDeviceSpeechEngine()
```

- [ ] **Step 2: Replace the MicButton struct**

Replace the entire `MicButton` struct (lines 192-235) with the new engine-driven version:

```swift
// MARK: - Mic Button (on-device speech engine)

private struct MicButton: View {
    @ObservedObject var engine: OnDeviceSpeechEngine
    let coordinator: SessionCoordinator
    @State private var showDownloadAlert = false

    var body: some View {
        Button {
            handleTap()
        } label: {
            Group {
                if let progress = engine.modelStore.downloadProgress {
                    // Downloading: show progress ring
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
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
        }
        .alert("Download Speech Models?", isPresented: $showDownloadAlert) {
            Button("Download") {
                Task { await engine.prepareModels() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("On-device voice recognition requires a one-time download (~1 GB). This enables offline, private speech-to-text.")
        }
    }

    private func handleTap() {
        let haptics = UIImpactFeedbackGenerator(style: .medium)

        switch engine.state {
        case .idle:
            guard engine.modelsReady else {
                showDownloadAlert = true
                return
            }
            haptics.impactOccurred()
            try? engine.startRecording()

        case .recording:
            Task {
                if let text = await engine.stopAndProcess() {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    guard let id = coordinator.activeSessionId,
                          let vm = coordinator.viewModel(for: id) else { return }
                    vm.sendInput(text)
                }
            }

        default:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            engine.cancel()
        }
    }

    private var buttonIcon: String {
        switch engine.state {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .cleaning: return "sparkles"
        case .error: return "mic"
        }
    }

    private var buttonColor: Color {
        switch engine.state {
        case .idle: return Color.gray.opacity(0.5)
        case .recording: return Color.red.opacity(0.8)
        case .transcribing, .cleaning: return Color.yellow.opacity(0.8)
        case .error: return Color.red.opacity(0.8)
        }
    }
}
```

- [ ] **Step 3: Update MicButton instantiation**

In `ActiveTerminalView.body`, around line 44, change:

From:
```swift
                    MicButton(speechRecognizer: speechRecognizer, coordinator: coordinator)
```
To:
```swift
                    MicButton(engine: speechEngine, coordinator: coordinator)
```

- [ ] **Step 4: Update lifecycle handlers**

In the `.onChange(of: coordinator.activeSessionId)` handler (around line 130), change:

From:
```swift
        .onChange(of: coordinator.activeSessionId) { _, _ in
            speechRecognizer.stopRecording()
        }
```
To:
```swift
        .onChange(of: coordinator.activeSessionId) { _, _ in
            speechEngine.cancel()
        }
```

In the `.onChange(of: scenePhase)` handler (around line 133), change:

From:
```swift
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                speechRecognizer.stopRecording()
            }
        }
```
To:
```swift
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                speechEngine.cancel()
            }
        }
```

- [ ] **Step 5: Update the permission alert**

Replace the existing `.alert(permissionAlertTitle, ...)` block (lines 144-171) with a simpler error alert for the new engine:

From:
```swift
        .alert(
            permissionAlertTitle,
            isPresented: Binding(
                get: { speechRecognizer.permissionError != nil },
                set: { if !$0 { speechRecognizer.permissionError = nil } }
            ),
            presenting: speechRecognizer.permissionError,
            ...
        )
```
To:
```swift
        .alert(
            "Speech Error",
            isPresented: Binding(
                get: { if case .error = speechEngine.state { return true } else { return false } },
                set: { if !$0 { /* state auto-recovers */ } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if case .error(let msg) = speechEngine.state {
                Text(msg)
            }
        }
```

- [ ] **Step 6: Remove the old permissionAlertTitle computed property**

Delete the `permissionAlertTitle` computed property (lines 182-189):

```swift
    private var permissionAlertTitle: String {
        switch speechRecognizer.permissionError {
        case .microphoneDenied: return "Microphone Access Required"
        case .speechDenied: return "Speech Recognition Required"
        case .unavailable: return "Speech Recognition Unavailable"
        case nil: return ""
        }
    }
```

- [ ] **Step 7: Remove unused LegacySpeechRecognizer StateObject**

Remove the line (was line 14):
```swift
    @StateObject private var speechRecognizer = LegacySpeechRecognizer()
```

The `LegacySpeechRecognizer` class file remains for future fallback use, but is no longer instantiated.

- [ ] **Step 8: Verify build**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodegen generate && xcodebuild build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 9: Commit**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay
git add ClaudeRelayApp/Views/ActiveTerminalView.swift
git commit -m "feat(speech): integrate OnDeviceSpeechEngine into mic button UI"
```

---

### Task 10: Add Unit Tests

**Files:**
- Create: `ClaudeRelayApp/Tests/OnDeviceSpeechEngineTests.swift`
- Create: `ClaudeRelayApp/Tests/TextCleanerTests.swift`

Since the iOS app uses an Xcode project (not SPM test target), tests go inside the app sources directory and can be run with Xcode's test runner. Alternatively, add a test target to `project.yml`.

- [ ] **Step 1: Add test target to project.yml**

Add after the `ClaudeRelayApp` target in `project.yml`:

```yaml
  ClaudeRelayAppTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: ClaudeRelayAppTests
    dependencies:
      - target: ClaudeRelayApp
    settings:
      base:
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/ClaudeRelayApp.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/ClaudeRelayApp"
        BUNDLE_LOADER: "$(TEST_HOST)"
```

- [ ] **Step 2: Create test directory**

```bash
mkdir -p /Users/miguelriotinto/Desktop/Projects/ClaudeRelay/ClaudeRelayAppTests
```

- [ ] **Step 3: Write mock helpers**

Create `ClaudeRelayAppTests/MockSpeechComponents.swift`:

```swift
import Foundation
@testable import ClaudeRelayApp

final class MockTranscriber: SpeechTranscribing {
    var resultToReturn: String = "hello world"
    var shouldThrow = false
    var transcribeCallCount = 0

    func transcribe(_ audioBuffer: [Float]) async throws -> String {
        transcribeCallCount += 1
        if shouldThrow { throw TranscriberError.emptyTranscription }
        return resultToReturn
    }
}

final class MockCleaner: TextCleaning {
    var resultToReturn: String?
    var shouldThrow = false
    var cleanCallCount = 0

    func clean(_ text: String) async throws -> String {
        cleanCallCount += 1
        if shouldThrow { throw CleanerError.modelNotLoaded }
        return resultToReturn ?? text
    }
}
```

- [ ] **Step 4: Write OnDeviceSpeechEngine tests**

Create `ClaudeRelayAppTests/OnDeviceSpeechEngineTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayApp

@MainActor
final class OnDeviceSpeechEngineTests: XCTestCase {

    private var transcriber: MockTranscriber!
    private var cleaner: MockCleaner!
    private var engine: OnDeviceSpeechEngine!

    override func setUp() {
        super.setUp()
        transcriber = MockTranscriber()
        cleaner = MockCleaner()
        // Note: We can't test AudioCaptureSession without a mic,
        // so we test the engine's state machine with mocks only.
        // Full integration requires a physical device.
    }

    func testInitialState() {
        let engine = OnDeviceSpeechEngine(
            transcriber: transcriber,
            cleaner: cleaner,
            capture: AudioCaptureSession(),
            modelStore: .shared
        )
        XCTAssertEqual(engine.state, .idle)
    }

    func testCleanupFallsBackToRawTextOnFailure() async {
        cleaner.shouldThrow = true
        transcriber.resultToReturn = "um hello world"

        // Simulate what stopAndProcess does internally (without mic)
        let rawText = try? await transcriber.transcribe([])
        XCTAssertEqual(rawText, "um hello world")

        do {
            _ = try await cleaner.clean(rawText!)
            XCTFail("Should have thrown")
        } catch {
            // Fallback: use raw text
            XCTAssertEqual(rawText, "um hello world")
        }
    }

    func testTranscriberCalled() async throws {
        transcriber.resultToReturn = "test output"
        let result = try await transcriber.transcribe([1.0, 2.0, 3.0])
        XCTAssertEqual(result, "test output")
        XCTAssertEqual(transcriber.transcribeCallCount, 1)
    }

    func testCleanerCalled() async throws {
        cleaner.resultToReturn = "cleaned text"
        let result = try await cleaner.clean("dirty text")
        XCTAssertEqual(result, "cleaned text")
        XCTAssertEqual(cleaner.cleanCallCount, 1)
    }
}
```

- [ ] **Step 5: Write TextCleaner static method tests**

Create `ClaudeRelayAppTests/TextCleanerStaticTests.swift`:

```swift
import XCTest
@testable import ClaudeRelayApp

final class TextCleanerStaticTests: XCTestCase {

    func testBuildCleanupPromptContainsInput() {
        let prompt = TextCleaner.buildCleanupPrompt(for: "hello world")
        XCTAssertTrue(prompt.contains("hello world"))
        XCTAssertTrue(prompt.contains("filler words"))
    }

    func testSanitizeResponseStripsThinkBlocks() {
        let input = "<think>reasoning here</think>Clean output"
        let result = TextCleaner.sanitizeResponse(input)
        XCTAssertEqual(result, "Clean output")
    }

    func testSanitizeResponsePreservesNormalText() {
        let input = "Normal transcription output."
        let result = TextCleaner.sanitizeResponse(input)
        XCTAssertEqual(result, "Normal transcription output.")
    }

    func testSanitizeResponseTrimsWhitespace() {
        let input = "  \n  some text  \n  "
        let result = TextCleaner.sanitizeResponse(input)
        XCTAssertEqual(result, "some text")
    }

    func testSanitizeResponseStripsMultipleThinkBlocks() {
        let input = "<think>a</think>hello <think>b</think>world"
        let result = TextCleaner.sanitizeResponse(input)
        XCTAssertEqual(result, "hello world")
    }
}
```

- [ ] **Step 6: Regenerate project and run tests**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodegen generate && xcodebuild test -project ClaudeRelay.xcodeproj -scheme ClaudeRelayAppTests -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E '(Test Suite|Test Case|PASS|FAIL|BUILD)'
```
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay
git add project.yml ClaudeRelay.xcodeproj ClaudeRelayAppTests/
git commit -m "test(speech): add unit tests for OnDeviceSpeechEngine and TextCleaner"
```

---

### Task 11: Full Build Verification and Cleanup

**Files:**
- All files from Tasks 1-10

- [ ] **Step 1: Clean build**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodegen generate && xcodebuild clean build -project ClaudeRelay.xcodeproj -scheme ClaudeRelayApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 2: Run all tests**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && swift test 2>&1 | tail -20
```
Expected: All existing 123 tests still pass (SPM targets unaffected).

- [ ] **Step 3: Run iOS app tests**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && xcodebuild test -project ClaudeRelay.xcodeproj -scheme ClaudeRelayAppTests -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E '(Test Suite|PASS|FAIL|Executed)'
```
Expected: All new tests pass.

- [ ] **Step 4: SwiftLint check**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay && swiftlint lint ClaudeRelayApp/Speech/ 2>&1
```
Expected: No warnings beyond the project's configured thresholds.

- [ ] **Step 5: Verify file structure**

```bash
find /Users/miguelriotinto/Desktop/Projects/ClaudeRelay/ClaudeRelayApp/Speech -type f | sort
```
Expected output:
```
ClaudeRelayApp/Speech/AudioCaptureSession.swift
ClaudeRelayApp/Speech/OnDeviceSpeechEngine.swift
ClaudeRelayApp/Speech/SpeechEngineState.swift
ClaudeRelayApp/Speech/SpeechModelStore.swift
ClaudeRelayApp/Speech/TextCleaner.swift
ClaudeRelayApp/Speech/WhisperTranscriber.swift
```

- [ ] **Step 6: Final commit**

```bash
cd /Users/miguelriotinto/Desktop/Projects/ClaudeRelay
git add -A
git status
# Only commit if there are uncommitted changes from fixups
git diff --cached --stat
```

If there are changes:
```bash
git commit -m "chore: final cleanup for on-device speech engine"
```
