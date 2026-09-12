import Foundation
import Combine
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Orchestrates the speech pipeline: record -> transcribe -> (local cleanup | cloud enhance) -> output.
/// This is the only class the UI talks to.
///
/// On iOS the engine observes `UIApplication.didReceiveMemoryWarning` to unload
/// the cleanup model under pressure. macOS has no equivalent notification — the
/// system handles memory pressure automatically — so the observer is omitted.
@MainActor
public final class OnDeviceSpeechEngine: ObservableObject {

    @Published public private(set) var state: SpeechEngineState = .idle
    @Published public private(set) var modelsReady: Bool = false
    /// 0.0–1.0 progress while loading models into memory. `nil` when not loading.
    @Published public private(set) var modelLoadProgress: Double?

    public let modelStore: SpeechModelStore

    private let transcriber: any SpeechTranscribing
    private let cleaner: any TextCleaning
    private let cloudEnhancer: CloudPromptEnhancer
    private let capture: AudioCaptureSession

    // Hold typed references for load/unload (protocols don't expose these)
    private let whisperTranscriber: WhisperTranscriber?
    private let textCleaner: TextCleaner?

    private var processingTask: Task<ProcessedText?, Never>?

    private var modelStoreSubscription: AnyCancellable?

    #if canImport(UIKit)
    private var memoryWarningObserver: NSObjectProtocol?
    #endif

    // MARK: - Init

    /// Production initializer.
    public convenience init(modelStore: SpeechModelStore? = nil) {
        let store = modelStore ?? .shared
        let transcriber = WhisperTranscriber.shared
        let cleaner = TextCleaner.shared
        self.init(
            transcriber: transcriber,
            cleaner: cleaner,
            cloudEnhancer: CloudPromptEnhancer(),
            capture: AudioCaptureSession(),
            modelStore: store,
            whisperTranscriber: transcriber,
            textCleaner: cleaner
        )
    }

    /// Test initializer — accepts protocol-typed mocks.
    public init(
        transcriber: any SpeechTranscribing,
        cleaner: any TextCleaning,
        cloudEnhancer: CloudPromptEnhancer = CloudPromptEnhancer(),
        capture: AudioCaptureSession,
        modelStore: SpeechModelStore,
        whisperTranscriber: WhisperTranscriber? = nil,
        textCleaner: TextCleaner? = nil
    ) {
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.cloudEnhancer = cloudEnhancer
        self.capture = capture
        self.modelStore = modelStore
        self.whisperTranscriber = whisperTranscriber
        self.textCleaner = textCleaner
        self.modelsReady = modelStore.modelsReady
        modelStoreSubscription = modelStore.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.modelsReady = self.modelStore.modelsReady
            }
        }
        #if canImport(UIKit)
        observeMemoryWarnings()
        #endif
    }

    #if canImport(UIKit)
    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    #endif

    // MARK: - Model Preparation

    public func prepareModels() async {
        do {
            try await modelStore.downloadAllModels()
            try await whisperTranscriber?.loadModel()
            textCleaner?.modelPath = modelStore.llmModelPath
            modelsReady = true
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Pre-load cached models into memory in the background on app launch.
    /// Updates `modelLoadProgress` so the mic button can show a progress ring
    /// instead of the mic icon while models load.
    /// No-op if models aren't downloaded, already loaded, or already loading.
    public func preloadInBackground() {
        guard modelStore.modelsReady else { return }
        guard whisperTranscriber?.isLoaded != true else { return }
        guard modelLoadProgress == nil else { return }

        modelLoadProgress = 0.0

        Task {
            do {
                // Whisper model is ~4x larger than LLM cleanup model
                try await whisperTranscriber?.loadModel { [weak self] progress in
                    Task { @MainActor in
                        guard self?.modelLoadProgress != nil else { return }
                        self?.modelLoadProgress = progress * 0.8
                    }
                }
                self.modelLoadProgress = 0.8

                textCleaner?.modelPath = modelStore.llmModelPath
                try? textCleaner?.loadModel(from: modelStore.llmModelPath)
                self.modelLoadProgress = 1.0

                // Brief pause lets user see 100% progress before UI dismissal
                try? await Task.sleep(for: .milliseconds(300))
                self.modelLoadProgress = nil
            } catch {
                self.modelLoadProgress = nil
            }
        }
    }

    // MARK: - Recording

    public func startRecording() async {
        guard state == .idle else { return }

        #if os(macOS)
        let micAccess = await AVCaptureDevice.requestAccess(for: .audio)
        guard micAccess else {
            state = .error("Microphone access denied — grant permission in System Settings > Privacy")
            Task {
                try? await Task.sleep(for: .seconds(5))
                if case .error = self.state { self.state = .idle }
            }
            return
        }
        #endif

        do {
            guard modelLoadProgress == nil else { return }

            // Load models into memory if cached but not yet loaded (e.g. after app relaunch)
            if modelsReady && whisperTranscriber?.isLoaded != true {
                state = .loadingModel
                modelLoadProgress = 0.0

                try await whisperTranscriber?.loadModel { [weak self] progress in
                    Task { @MainActor in
                        guard self?.state == .loadingModel else { return }
                        self?.modelLoadProgress = progress * 0.8
                    }
                }
                modelLoadProgress = 0.8

                // Phase 2: LLM cleanup model (~20% of total)
                textCleaner?.modelPath = modelStore.llmModelPath
                try? textCleaner?.loadModel(from: modelStore.llmModelPath)
                modelLoadProgress = 1.0

                // Brief pause so the user sees 100% before the modal dismisses
                try? await Task.sleep(for: .milliseconds(400))
                modelLoadProgress = nil
            }

            try capture.start()
            state = .recording
        } catch {
            modelLoadProgress = nil
            state = .error(error.localizedDescription)
            Task {
                try? await Task.sleep(for: .seconds(3))
                if case .error = self.state { self.state = .idle }
            }
        }
    }

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

    /// Stop recording and process the audio.
    /// - `smartCleanup`: use local LLM for filler removal
    /// - `promptEnhancement`: use cloud Haiku for prompt rewriting (overrides cleanup)
    /// - `bearerToken` / `region`: required when promptEnhancement is true
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

    public func cancel() {
        processingTask?.cancel()
        processingTask = nil
        if capture.isRecording {
            _ = capture.stop()
        }
        state = .idle
    }

    // MARK: - Memory

    #if canImport(UIKit)
    private func observeMemoryWarnings() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.textCleaner?.unload()
        }
    }
    #endif
}
