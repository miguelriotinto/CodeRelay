import Foundation
import WhisperKit

/// Manages model downloads, caching, and disk lifecycle for the speech pipeline.
///
/// Storage paths are intentionally per-platform to preserve existing user downloads:
/// - iOS uses `<AppSupport>/Models/` and the `speechModelStore.whisperDownloaded` key
/// - macOS uses `<AppSupport>/ClaudeRelay/Models/` and the `com.clauderelay.mac.whisperDownloaded` key
@MainActor
public final class SpeechModelStore: ObservableObject {

    public static let shared = SpeechModelStore()

    @Published public private(set) var whisperReady = false
    @Published public private(set) var llmDownloaded = false
    @Published public private(set) var downloadProgress: Double?

    #if os(iOS)
    private static let whisperReadyKey = "speechModelStore.whisperDownloaded"
    #else
    private static let whisperReadyKey = "com.clauderelay.mac.whisperDownloaded"
    #endif

    /// HuggingFace URL for the Qwen 3.5 0.8B Q4_K_M GGUF model.
    private static let llmModelURL = URL(
        string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf"
    )!

    private static let llmFileName = "qwen35-0.8b-q4km.gguf"

    public var modelsReady: Bool { whisperReady && llmDownloaded }

    // MARK: - Paths

    /// Base directory for speech models. Platform-specific to preserve existing installs:
    /// iOS uses `<AppSupport>/Models/`; macOS uses `<AppSupport>/ClaudeRelay/Models/`
    /// so models are isolated from any other app's Application Support usage.
    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(iOS)
        return appSupport.appendingPathComponent("Models", isDirectory: true)
        #else
        // "ClaudeRelay" is the on-disk directory name existing Macs already
        // have their downloaded models in. It is the product's former name and
        // is kept on purpose: renaming it would force a multi-GB re-download.
        return appSupport
            .appendingPathComponent("ClaudeRelay", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        #endif
    }

    /// Path to the LLM GGUF file on disk.
    public var llmModelPath: URL {
        modelsDirectory.appendingPathComponent(Self.llmFileName)
    }

    // MARK: - Init

    private init() {
        llmDownloaded = FileManager.default.fileExists(atPath: llmModelPath.path)
        whisperReady = UserDefaults.standard.bool(forKey: Self.whisperReadyKey)
    }

    // MARK: - Download

    /// Download both models. Updates `downloadProgress` during the process.
    // 50/50 split approximates relative download sizes
    public func downloadAllModels() async throws {
        downloadProgress = 0.0

        // Phase 1: Whisper model — download with progress, then load
        let whisperFolder = try await WhisperKit.download(
            variant: "openai_whisper-small.en",
            progressCallback: { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress.fractionCompleted * 0.5
                }
            }
        )
        // Load from the downloaded folder (skip re-download)
        _ = try await WhisperKit(
            modelFolder: whisperFolder.path,
            verbose: false,
            prewarm: true,
            download: false
        )
        whisperReady = true
        UserDefaults.standard.set(true, forKey: Self.whisperReadyKey)
        downloadProgress = 0.5

        // Phase 2: LLM GGUF download (if not already on disk)
        if !llmDownloaded {
            try await downloadLLMModel()
        }
        llmDownloaded = true

        downloadProgress = 1.0
        try? await Task.sleep(for: .milliseconds(500))
        downloadProgress = nil
    }

    /// Download the LLM GGUF file from HuggingFace with progress reporting.
    private func downloadLLMModel() async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let destination = llmModelPath
        let (tempURL, response) = try await downloadWithProgress(
            from: Self.llmModelURL,
            progressHandler: { [weak self] fraction in
                self?.downloadProgress = 0.5 + fraction * 0.5
            }
        )

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ModelStoreError.downloadFailed
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)

        // Exclude from iCloud backup
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDest = destination
        try mutableDest.setResourceValues(resourceValues)
    }

    /// Download a file using a delegate-based URLSession to get progress updates.
    private func downloadWithProgress(
        from url: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        let delegate = DownloadProgressDelegate(progressHandler: progressHandler)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(from: url)

        // URLSession may delete the temp file after returning, so move to a safe location
        let safeTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: tempURL, to: safeTempURL)

        return (safeTempURL, response)
    }

    /// Delete all downloaded models to free disk space.
    public func deleteModels() {
        try? FileManager.default.removeItem(at: modelsDirectory)
        whisperReady = false
        llmDownloaded = false
        UserDefaults.standard.removeObject(forKey: Self.whisperReadyKey)
    }

    /// Total bytes used by models on disk.
    public var totalModelSize: Int64 {
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else { return 0 }
        let enumerator = FileManager.default.enumerator(
            at: modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        )
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            guard
                let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                resourceValues.isDirectory != true,
                let size = resourceValues.fileSize
            else {
                continue
            }
            let (partial, _) = total.addingReportingOverflow(Int64(clamping: size))
            total = partial
        }
        return total
    }
}

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    // `@MainActor @Sendable`: the closure only captures main-actor-isolated state,
    // so it's safe to move across isolation domains. Required by Swift 6 because
    // DownloadProgressDelegate is @unchecked Sendable and URLSession invokes the
    // delegate callbacks from its own serial queue.
    private let progressHandler: @MainActor @Sendable (Double) -> Void

    init(progressHandler: @MainActor @Sendable @escaping (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let handler = progressHandler
        Task { @MainActor in handler(fraction) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Required by protocol; actual file handling is done in the async caller.
    }
}

public enum ModelStoreError: Error, LocalizedError {
    case downloadFailed
    case insufficientDiskSpace

    public var errorDescription: String? {
        switch self {
        case .downloadFailed: return "Failed to download speech model"
        case .insufficientDiskSpace: return "Not enough storage for speech models (~1 GB required)"
        }
    }
}
