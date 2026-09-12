import AVFoundation

/// Captures microphone audio and accumulates a 16kHz mono Float32 buffer.
/// Not an actor — must be called from @MainActor (OnDeviceSpeechEngine).
///
/// On iOS, configures `AVAudioSession` for record+measurement. On macOS, the
/// system handles mic permissions via `NSMicrophoneUsageDescription` in
/// Info.plist and the audio-input entitlement — `AVAudioSession` is iOS-only.
public final class AudioCaptureSession {

    private let audioEngine = AVAudioEngine()
    private var buffer: [Float] = []
    public private(set) var isRecording = false

    /// Minimum recording duration in seconds to avoid empty transcriptions.
    public static let minimumDuration: TimeInterval = 0.5

    /// Maximum recording duration; auto-stops to cap memory.
    /// Backgrounded recordings that never call stop() would otherwise grow
    /// at 64 KB/s (16 kHz × 4 bytes × 1 channel) unbounded.
    public static let maximumDuration: TimeInterval = 300   // 5 minutes

    private var recordingStart: Date?
    private var autoStopTask: Task<Void, Never>?

    public init() {}

    /// Configure audio session (iOS), install tap on input node, start engine.
    public func start() throws {
        guard !isRecording else { return }
        buffer.removeAll()

        #if canImport(UIKit)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

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

        // Cap recording to prevent unbounded Float-sample memory growth in backgrounded sessions
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maximumDuration))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            _ = self.stop()
        }
    }

    /// Stop engine, deactivate audio session (iOS), return accumulated buffer.
    /// Returns nil if recording was shorter than `minimumDuration`.
    public func stop() -> [Float]? {
        guard isRecording else { return nil }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
        autoStopTask?.cancel()
        autoStopTask = nil

        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        #endif

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

public enum AudioCaptureError: Error, LocalizedError {
    case formatCreationFailed
    case converterCreationFailed

    public var errorDescription: String? {
        switch self {
        case .formatCreationFailed: return "Failed to create 16kHz audio format"
        case .converterCreationFailed: return "Failed to create audio converter"
        }
    }
}
