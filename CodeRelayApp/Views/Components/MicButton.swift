import SwiftUI
import CodeRelayClient
import CodeRelaySpeech

// MARK: - Mic Button (on-device speech engine)

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
                Image(systemName: effectiveIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 44, height: 44)
        .background(effectiveBackgroundColor)
        .clipShape(Circle())
        .animation(.easeInOut(duration: 0.2), value: effectiveBackgroundColor)
    }

    private var longPressGesture: some Gesture {
        // Long press in continuous mode: one-shot PTT without disabling continuous listening
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

    // MARK: - Unified icon & color

    private var effectiveIcon: String {
        if settings.continuousListeningEnabled {
            switch continuousEngine.state {
            case .idle:
                return "mic"
            case .listening, .detectingWakeWord:
                return "waveform"
            case .armed, .recording, .detectingTurnEnd:
                return "mic.fill"
            case .transcribing:
                return "waveform"
            case .cleaning:
                return "sparkles"
            case .outputting:
                return "text.bubble"
            case .error:
                return "mic"
            }
        } else {
            switch engine.state {
            case .idle, .loadingModel: return "mic"
            case .recording: return "mic.fill"
            case .transcribing: return "waveform"
            case .cleaning: return "sparkles"
            case .error: return "mic"
            }
        }
    }

    private var effectiveBackgroundColor: SwiftUI.Color {
        if settings.continuousListeningEnabled {
            switch continuousEngine.state {
            case .idle:
                return SwiftUI.Color.gray.opacity(0.5)
            case .listening, .detectingWakeWord:
                return SwiftUI.Color.blue.opacity(0.8)
            case .armed, .recording, .detectingTurnEnd:
                return SwiftUI.Color.red.opacity(0.8)
            case .transcribing, .cleaning:
                return SwiftUI.Color.yellow.opacity(0.8)
            case .outputting:
                return SwiftUI.Color.yellow.opacity(0.8)
            case .error:
                return SwiftUI.Color.red.opacity(0.8)
            }
        } else {
            switch engine.state {
            case .idle, .loadingModel:
                return SwiftUI.Color.green.opacity(0.8)
            case .recording:
                return SwiftUI.Color.red.opacity(0.8)
            case .transcribing, .cleaning:
                return SwiftUI.Color.yellow.opacity(0.8)
            case .error:
                return SwiftUI.Color.red.opacity(0.8)
            }
        }
    }
}
