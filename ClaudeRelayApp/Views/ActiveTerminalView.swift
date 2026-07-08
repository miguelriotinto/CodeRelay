import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit
import ClaudeRelaySpeech
import GameController

/// Detail pane: thin toolbar + terminal + optional key bar.
struct ActiveTerminalView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Binding var columnVisibility: NavigationSplitViewVisibility
    var onDisconnect: () -> Void
    @State private var showKeyBar = true
    @State private var isKeyboardVisible = false
    @State private var hasHardwareKeyboard = GCKeyboard.coalesced != nil
    @State private var showQROverlay = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    /// Drives the swipe-flash sweep when the session-name button triggers a
    /// refresh. 0 parks the band offscreen left, 1 offscreen right — so the
    /// effect is invisible at both endpoints and needs no visibility flag.
    @State private var refreshSweepProgress: CGFloat = 0
    @StateObject private var speechEngine = OnDeviceSpeechEngine()
    @StateObject private var continuousEngine = ContinuousListeningEngine.makeDefault(
        options: AppSettings.shared.currentSpeechOptions()
    )
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                if let id = coordinator.activeSessionId,
                   let vm = coordinator.viewModel(for: id) {
                    // Single host reused across session switches so each
                    // terminal's SwiftTerm scrollback survives the swap.
                    TerminalHostView(
                        coordinator: coordinator,
                        fontSize: CGFloat(settings.terminalFontSize),
                        isKeyboardVisible: $isKeyboardVisible
                    )

                    if showKeyBar {
                        KeyboardAccessory { data in
                            vm.sendInput(data)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Active Session",
                        systemImage: "terminal",
                        description: Text("Swipe from the left edge or create a new session.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear {
                speechEngine.preloadInBackground()
            }

            // Floating buttons: mic + keyboard toggle (only when a terminal session is active)
            if coordinator.activeSessionId != nil {
                HStack(spacing: 10) {
                    MicButton(
                        engine: speechEngine,
                        settings: settings,
                        coordinator: coordinator,
                        continuousEngine: continuousEngine
                    )

                    Button {
                        if settings.hapticFeedbackEnabled {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        if isKeyboardVisible {
                            NotificationCenter.default.post(
                                name: .terminalResignFocus, object: nil
                            )
                        } else {
                            NotificationCenter.default.post(
                                name: .terminalRequestFocus, object: nil
                            )
                        }
                    } label: {
                        Image(systemName: isKeyboardVisible
                              ? "keyboard.chevron.compact.down"
                              : "keyboard")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.gray.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .disabled(hasHardwareKeyboard)
                    .opacity(hasHardwareKeyboard ? 0.35 : 1.0)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            }
        }
        // Swipe flash: a soft white band sweeping left → right across the
        // terminal (~1 s) that confirms the session-name refresh fired — the
        // motion reads as "the screen is being rewritten". Purely decorative,
        // so it never intercepts touches meant for the terminal underneath.
        .overlay {
            GeometryReader { geo in
                let bandWidth = geo.size.width * 0.45
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.30), location: 0.5),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: bandWidth)
                // progress 0 → fully offscreen left, 1 → fully offscreen right.
                .offset(x: -bandWidth + (geo.size.width + 2 * bandWidth) * refreshSweepProgress)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 6) {
                ToolbarIconButton(icon: "sidebar.left") {
                    withAnimation {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                }
                .accessibilityLabel("Toggle Sidebar")
                ToolbarIconButton(icon: "server.rack") { onDisconnect() }
                    .accessibilityLabel("Disconnect")
                ToolbarIconButton(icon: "fn", isActive: showKeyBar) { showKeyBar.toggle() }
                    .accessibilityLabel(showKeyBar ? "Hide Key Bar" : "Show Key Bar")

                ConnectionQualityDot(quality: coordinator.connection.connectionQuality, size: 8)

                if let id = coordinator.activeSessionId {
                    if let createdAt = coordinator.createdAt(for: id) {
                        SessionUptimeView(since: createdAt)
                    }
                }

                if coordinator.sessionsAwaitingInput.isEmpty {
                    sessionTabBar(flashOn: false)
                } else {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let flashOn = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                        sessionTabBar(flashOn: flashOn)
                    }
                }

                if coordinator.activeSessionId != nil {
                    ToolbarIconButton(icon: "qrcode") {
                        showQROverlay = true
                    }
                    .accessibilityLabel("Share Session")
                }

                if let id = coordinator.activeSessionId {
                    Text(coordinator.name(for: id))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: 100)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .layoutPriority(1)
                        // Tap → ask the server to SIGWINCH the session's foreground
                        // process group so the running app re-emits its screen (the
                        // same replay the keyboard toggle triggers via resize — fresh
                        // bytes, not a repaint of the possibly-corrupt local grid),
                        // plus a local geometry re-sync via the notification.
                        // Long-press → rename. The tap gesture is declared first so
                        // it doesn't swallow the long-press.
                        .onTapGesture {
                            if settings.hapticFeedbackEnabled {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            coordinator.viewModel(for: id)?.sendRefresh()
                            NotificationCenter.default.post(name: .terminalForceRedraw, object: nil)
                            flashRefreshFeedback()
                        }
                        .onLongPressGesture {
                            renameText = coordinator.name(for: id)
                            showRenameAlert = true
                        }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.black)
        }
        .background(.black)
        .ignoresSafeArea(.container, edges: .horizontal)
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: coordinator.activeSessionId) { _, _ in
            showQROverlay = false
            speechEngine.cancel()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                speechEngine.cancel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
            hasHardwareKeyboard = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            hasHardwareKeyboard = GCKeyboard.coalesced != nil
        }
        .alert(
            "Speech Error",
            isPresented: Binding(
                get: { if case .error = speechEngine.state { return true } else { return false } },
                set: { _ in }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if case .error(let msg) = speechEngine.state {
                Text(msg)
            }
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
        .task(id: optionsHash) {
            continuousEngine.onUtteranceReady = { text in
                guard let id = coordinator.activeSessionId,
                      let vm = coordinator.viewModel(for: id) else { return }
                vm.sendInput(text)
            }
            continuousEngine.updateOptions(settings.currentSpeechOptions())
            if settings.continuousListeningEnabled && scenePhase == .active {
                await continuousEngine.enable()
            } else {
                await continuousEngine.disable()
            }
        }
        .overlay {
            if showQROverlay, let id = coordinator.activeSessionId {
                QRCodeOverlay(
                    sessionId: id,
                    sessionName: coordinator.name(for: id),
                    onDismiss: { showQROverlay = false }
                )
            }
        }
    }

    /// Sweep the flash band across the terminal over ~1 s. Progress is snapped
    /// back to 0 (offscreen left) without animation first, so rapid re-taps
    /// restart the sweep cleanly instead of reversing mid-flight.
    private func flashRefreshFeedback() {
        var restart = Transaction()
        restart.disablesAnimations = true
        withTransaction(restart) { refreshSweepProgress = 0 }
        withAnimation(.easeInOut(duration: 1.0)) { refreshSweepProgress = 1 }
    }

    private var optionsHash: String {
        let s = settings
        return [
            "\(s.continuousListeningEnabled)",
            "\(s.smartCleanupEnabled)",
            "\(s.promptEnhancementEnabled)",
            s.wakeWord,
            "\(scenePhase)"
        ].joined(separator: "|")
    }

    @ViewBuilder
    private func sessionTabBar(flashOn: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(coordinator.activeSessions.enumerated()), id: \.element.id) { index, session in
                        let isSelected = session.id == coordinator.activeSessionId
                        let agentId = coordinator.activeAgent(for: session.id)
                        let needsAttention = coordinator.sessionsAwaitingInput.contains(session.id)
                        Button {
                            if settings.hapticFeedbackEnabled {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            Task { await coordinator.switchToSession(id: session.id) }
                        } label: {
                            SessionTab(
                                number: index + 1,
                                isSelected: isSelected,
                                agentId: agentId,
                                needsAttention: needsAttention,
                                flashOn: flashOn
                            )
                        }
                        .buttonStyle(.plain)
                        .id(session.id)
                    }
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TabStripWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(TabStripWidthKey.self) { _ in
                if let id = coordinator.activeSessionId {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: nil)
                    }
                }
            }
            .onChange(of: coordinator.activeSessionId) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newID, anchor: nil)
                }
            }
            .onAppear {
                if let id = coordinator.activeSessionId {
                    proxy.scrollTo(id, anchor: nil)
                }
            }
        }
    }

}

// MARK: - Preference Key for Tab Strip Width

private struct TabStripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Toolbar Icon Button

/// Compact icon button for the status bar toolbar.
private struct ToolbarIconButton: View {
    let icon: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            if AppSettings.shared.hapticFeedbackEnabled {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? .black : SwiftUI.Color.white.opacity(0.7))
                .frame(minWidth: 26, minHeight: 22)
                .background(isActive ? Color.white : Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// Individual session tab. Flash phase is driven by a shared TimelineView clock
/// in the parent, so we don't spin up one Timer.publish per tab.
private struct SessionTab: View {
    let number: Int
    let isSelected: Bool
    let agentId: String?
    let needsAttention: Bool
    /// Shared flash phase passed down from the parent's TimelineView.
    /// Ignored by tabs that don't need attention.
    let flashOn: Bool

    var body: some View {
        Text("\(number)")
            .font(.system(size: 12, weight: isSelected ? .bold : .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(minWidth: 26, minHeight: 22)
            .background(tabBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selectionBorderColor, lineWidth: isSelected ? 2 : 0)
            )
            .animation(.easeInOut(duration: 0.15), value: flashOn)
    }

    private var selectionBorderColor: SwiftUI.Color { .white }

    private var agentColor: SwiftUI.Color {
        AgentColorPalette.color(for: agentId)
    }

    private var tabBackground: SwiftUI.Color {
        if needsAttention {
            return flashOn ? agentColor : SwiftUI.Color.white.opacity(0.15)
        }
        if agentId != nil { return agentColor }
        return SwiftUI.Color.white.opacity(0.15)
    }
}

// MARK: - Notification for requesting terminal focus

extension Notification.Name {
    static let terminalRequestFocus = Notification.Name("terminalRequestFocus")
    static let terminalResignFocus = Notification.Name("terminalResignFocus")
    static let toggleSpeechRecording = Notification.Name("toggleSpeechRecording")
    /// Force a full repaint of the active terminal (clears rare glyph overlap).
    /// Posted when the user taps the session-name badge; handled by `HostCoordinator`.
    static let terminalForceRedraw = Notification.Name("terminalForceRedraw")
}

// MARK: - Session Uptime

private struct SessionUptimeView: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(formatUptime(from: since, to: context.date))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(SwiftUI.Color.white.opacity(0.5))
        }
    }

    private func formatUptime(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if days > 0 {
            return String(format: "%dd %02d:%02d:%02d", days, hours, minutes, seconds)
        }
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
