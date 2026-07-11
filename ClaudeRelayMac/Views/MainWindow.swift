import SwiftUI
import AppKit
import ClaudeRelayClient
import ClaudeRelaySpeech

struct MainWindow: View {
    @StateObject private var serverList = ServerListViewModel()
    @StateObject private var speechEngine = OnDeviceSpeechEngine()
    @StateObject private var continuousEngine = ContinuousListeningEngine.makeDefault(
        options: AppSettings.shared.currentSpeechOptions()
    )
    @ObservedObject private var settings = AppSettings.shared
    @State private var coordinator: SessionCoordinator?
    @State private var showServerList = false
    @State private var loadFailure: String?

    var body: some View {
        Group {
            if let coordinator {
                WorkspaceView(
                    coordinator: coordinator,
                    speechEngine: speechEngine,
                    continuousEngine: continuousEngine,
                    settings: settings
                )
            } else if let failure = loadFailure {
                FailureView(message: failure) { showServerList = true }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Select a server to connect")
                        .foregroundStyle(.secondary)
                    Button("Choose Server") { showServerList = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.black)
        .task { await presentServerList() }
        .onAppear { speechEngine.preloadInBackground() }
        .sheet(isPresented: $showServerList) {
            NavigationStack {
                ServerListWindow { config in
                    Task { await connect(to: config) }
                    showServerList = false
                }
            }
            .background(.black)
            .presentationBackground(.black)
        }
        .onDisappear {
            coordinator?.tearDown()
            ActiveCoordinatorRegistry.shared.clear()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showServerList)) { _ in
            showServerList = true
        }
        .preferredColorScheme(.dark)
        .focusedValue(\.sessionCoordinator, coordinator)
    }

    private func presentServerList() async {
        showServerList = true
    }

    private func connect(to config: ConnectionConfig) async {
        loadFailure = nil
        do {
            guard let token = try AuthManager.shared.loadToken(for: config.id) else {
                loadFailure = "No token stored for this server."
                return
            }
            let c = SessionCoordinator(config: config, token: token)
            coordinator = c
            await c.start()
            if let err = c.errorMessage {
                loadFailure = err
                coordinator = nil
            } else {
                ActiveCoordinatorRegistry.shared.register(coordinator: c, serverName: config.name)
            }
        } catch {
            loadFailure = error.localizedDescription
        }
    }

}

private struct WorkspaceView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var speechEngine: OnDeviceSpeechEngine
    @ObservedObject var continuousEngine: ContinuousListeningEngine
    @ObservedObject var settings: AppSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showQRPopover = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    /// Drives the swipe-flash sweep when the session-name button triggers a
    /// refresh. 0 parks the band offscreen above, 1 offscreen below — so the
    /// effect is invisible at both endpoints and needs no visibility flag.
    @State private var refreshSweepProgress: CGFloat = 0

    private var optionsHash: String {
        let s = settings
        return [
            "\(s.continuousListeningEnabled)",
            "\(s.smartCleanupEnabled)",
            "\(s.promptEnhancementEnabled)",
            s.wakeWord
        ].joined(separator: "|")
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebarView(coordinator: coordinator)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if coordinator.activeSessionId != nil {
                    // Single host reused across session switches so each
                    // terminal's SwiftTerm scrollback survives the swap.
                    TerminalContainerView(coordinator: coordinator, fontSize: CGFloat(settings.terminalFontSize))
                        .padding(.leading, 6)
                        // Swipe flash: a soft white band sweeping top → bottom
                        // across the terminal (~1 s) confirming the session-name
                        // refresh fired. Purely decorative, so it never intercepts
                        // clicks meant for the terminal underneath.
                        .overlay {
                            GeometryReader { geo in
                                let bandHeight = geo.size.height * 0.45
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .white.opacity(0.30), location: 0.5),
                                        .init(color: .clear, location: 1),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: bandHeight)
                                // progress 0 → offscreen above, 1 → offscreen below.
                                .offset(y: -bandHeight + (geo.size.height + 2 * bandHeight) * refreshSweepProgress)
                            }
                            .allowsHitTesting(false)
                        }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No session selected")
                            .foregroundStyle(.secondary)
                        Button("New Session") {
                            Task { await coordinator.createNewSession() }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                StatusBarView(coordinator: coordinator)
            }
            .background(.black)
        }
        .toolbar {
            // LEFT group (leading): sidebar toggle is auto-injected by
            // NavigationSplitView; then Servers, then Record (mic).
            ToolbarItem(placement: .navigation) {
                Button {
                    NotificationCenter.default.post(name: .showServerList, object: nil)
                } label: {
                    Label("Servers", systemImage: "server.rack")
                }
            }
            ToolbarItem(placement: .navigation) {
                MacMicButton(
                    engine: speechEngine,
                    coordinator: coordinator,
                    hasActiveSession: coordinator.activeSessionId != nil,
                    continuousEngine: continuousEngine,
                    settings: settings
                )
            }
            // RIGHT group (trailing / top-right): QR code, then session name.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showQRPopover = true
                } label: {
                    Label("Share via QR Code", systemImage: "qrcode")
                }
                .disabled(coordinator.activeSessionId == nil)
                .popover(isPresented: $showQRPopover, arrowEdge: .bottom) {
                    if let id = coordinator.activeSessionId {
                        QRCodePopover(sessionId: id, sessionName: coordinator.name(for: id))
                    }
                }
            }
            if let id = coordinator.activeSessionId {
                ToolbarItem(placement: .primaryAction) {
                    // Session-name badge (matches iOS/Android). Click → ask the
                    // server to SIGWINCH the session's foreground process group
                    // so the running app re-emits its screen (fresh bytes, not a
                    // repaint of the possibly-stale local grid), plus a local
                    // full repaint via `.terminalForceRedraw`, plus the swipe
                    // flash. Long-press (right-click menu) → rename.
                    Text(coordinator.name(for: id))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: 160)
                        // Match the 26 pt mic button so the badge fills the
                        // toolbar row top-to-bottom instead of floating shorter.
                        .frame(height: 26)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture {
                            coordinator.viewModel(for: id)?.sendRefresh()
                            NotificationCenter.default.post(name: .terminalForceRedraw, object: nil)
                            flashRefreshFeedback()
                        }
                        .contextMenu {
                            Button("Rename Session…") {
                                renameText = coordinator.name(for: id)
                                showRenameAlert = true
                            }
                        }
                        .help("Click to refresh · right-click to rename")
                }
            }
        }
        .toolbarBackground(.black, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .focusedValue(\.sidebarVisibility, $columnVisibility)
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
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            Task { await continuousEngine.disable() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task {
                if settings.continuousListeningEnabled {
                    await continuousEngine.enable()
                }
            }
        }
        .sheet(isPresented: $coordinator.showQRScanner) {
            QRScannerSheet(coordinator: coordinator)
        }
        .sheet(isPresented: $coordinator.isRecovering) {
            RecoverySheet(
                phase: coordinator.recoveryPhase,
                onCancel: {
                    coordinator.cancelRecovery()
                }
            )
            .interactiveDismissDisabled()
        }
        .alert("Cannot Open Session", isPresented: $coordinator.sessionAttachFailed) {
            Button("OK", role: .cancel) {
                coordinator.sessionAttachError = nil
            }
        } message: {
            Text(coordinator.sessionAttachError ?? "Unable to attach to this session.")
        }
        .alert("Connection Lost", isPresented: $coordinator.connectionTimedOut) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Unable to reconnect to the server. Check your network and try reconnecting.")
        }
        .alert("Rename Session", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, let id = coordinator.activeSessionId {
                    coordinator.setName(trimmed, for: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Sweep the flash band across the terminal over ~1 s. Progress is snapped
    /// back to 0 (offscreen above) without animation first, so rapid re-clicks
    /// restart the sweep cleanly instead of reversing mid-flight.
    private func flashRefreshFeedback() {
        var restart = Transaction()
        restart.disablesAnimations = true
        withTransaction(restart) { refreshSweepProgress = 0 }
        withAnimation(.easeInOut(duration: 1.0)) { refreshSweepProgress = 1 }
    }
}

private struct RecoverySheet: View {
    let phase: SharedSessionCoordinator.RecoveryPhase
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Reconnecting")
                .font(.headline)
            Text(phase.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: phase.label)
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .controlSize(.large)
                .padding(.bottom, 16)
        }
        .frame(width: 280, height: 200)
    }
}

private struct FailureView: View {
    let message: String
    let onChooseServer: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Cannot connect")
                .font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Choose Server") { onChooseServer() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Mic Button (matches iOS styling)

private struct MacMicButton: View {
    @ObservedObject var engine: OnDeviceSpeechEngine
    let coordinator: SessionCoordinator?
    let hasActiveSession: Bool
    @ObservedObject var continuousEngine: ContinuousListeningEngine
    @ObservedObject var settings: AppSettings
    @State private var showDownloadAlert = false
    @State private var continuousPausedByUser = false

    private var activeProgress: Double? {
        engine.modelStore.downloadProgress ?? engine.modelLoadProgress
    }

    var body: some View {
        Button(action: handleTap) {
            Group {
                if let progress = activeProgress {
                    progressRing(progress)
                } else {
                    Image(systemName: effectiveIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 26, height: 26)
            .background(effectiveBackgroundColor)
            .clipShape(Circle())
            .animation(.easeInOut(duration: 0.2), value: effectiveBackgroundColor)
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                guard settings.continuousListeningEnabled else { return }
                beginTemporaryPTT()
            }
        )
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(engine.state.description)
        .alert("Download Speech Models?", isPresented: $showDownloadAlert) {
            Button("Download") {
                Task { await engine.prepareModels() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("On-device voice recognition requires a one-time download (~1 GB). This enables offline, private speech-to-text.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSpeechRecording)) { _ in
            guard !isDisabled else { return }
            handleTap()
        }
    }

    private func progressRing(_ progress: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.4), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)
        }
        .frame(width: 16, height: 16)
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
        await engine.startRecording()
        try? await Task.sleep(for: .seconds(2))
        let text = await engine.stopAndProcess(options: settings.currentSpeechOptions())
        if let text, !text.isEmpty,
           let coordinator,
           let id = coordinator.activeSessionId,
           let vm = coordinator.viewModel(for: id) {
            vm.sendInput(text)
        }
    }

    private func handlePTTTap() {
        switch engine.state {
        case .idle:
            guard engine.modelsReady else {
                showDownloadAlert = true
                return
            }
            Task { await engine.startRecording() }
        case .recording:
            Task {
                let text = await engine.stopAndProcess(options: settings.currentSpeechOptions())
                if let text, !text.isEmpty,
                   let coordinator,
                   let id = coordinator.activeSessionId,
                   let vm = coordinator.viewModel(for: id) {
                    vm.sendInput(text)
                }
            }
        case .error:
            engine.cancel()
        default:
            break
        }
    }

    private var isDisabled: Bool {
        switch engine.state {
        case .loadingModel, .transcribing, .cleaning:
            return true
        default:
            return !hasActiveSession || activeProgress != nil
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

    private var effectiveBackgroundColor: Color {
        if settings.continuousListeningEnabled {
            switch continuousEngine.state {
            case .idle:
                return Color.gray.opacity(0.5)
            case .listening, .detectingWakeWord:
                return Color.blue.opacity(0.8)
            case .armed, .recording, .detectingTurnEnd:
                return Color.red.opacity(0.8)
            case .transcribing, .cleaning:
                return Color.yellow.opacity(0.8)
            case .outputting:
                return Color.yellow.opacity(0.8)
            case .error:
                return Color.red.opacity(0.8)
            }
        } else {
            switch engine.state {
            case .idle, .loadingModel:
                return Color.green.opacity(0.8)
            case .recording:
                return Color.red.opacity(0.8)
            case .transcribing, .cleaning:
                return Color.yellow.opacity(0.8)
            case .error:
                return Color.red.opacity(0.8)
            }
        }
    }
}
