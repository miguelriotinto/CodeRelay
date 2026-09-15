import SwiftUI
import AppKit
import CodeRelayClient

struct MainWindow: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var coordinator: SessionCoordinator?
    @State private var showServerList = false
    @State private var loadFailure: String?

    var body: some View {
        Group {
            if let coordinator {
                WorkspaceView(
                    coordinator: coordinator,
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
        .onReceive(NotificationCenter.default.publisher(for: .connectToServer)) { notification in
            if let config = notification.object as? ConnectionConfig {
                Task { await connect(to: config) }
            }
        }
        // Re-sync push registration when APNs vends/rotates a token or the user
        // changes push settings (parity with iOS WorkspaceView).
        .onReceive(PushTokenBridge.shared.$deviceToken) { _ in Task { await syncPush() } }
        .onChange(of: settings.pushNotificationsEnabled) { _, _ in Task { await syncPush() } }
        .onChange(of: settings.pushNotifyOnFinished) { _, _ in Task { await syncPush() } }
        .preferredColorScheme(.dark)
        .focusedValue(\.sessionCoordinator, coordinator)
    }

    /// Reconcile this device's push registration with current settings/token.
    private func syncPush() async {
        guard let coordinator else { return }
        await coordinator.syncPushRegistration(
            pushEnabled: settings.pushNotificationsEnabled,
            notifyOnFinished: settings.pushNotifyOnFinished)
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
                await c.syncPushRegistration(
                    pushEnabled: AppSettings.shared.pushNotificationsEnabled,
                    notifyOnFinished: AppSettings.shared.pushNotifyOnFinished)
            }
        } catch {
            loadFailure = error.localizedDescription
        }
    }

}

private struct WorkspaceView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var settings: AppSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showQRPopover = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    /// Blackout opacity for the session-name reload: 0 shows the terminal, 1
    /// hides it behind opaque black while the server's copy is swapped in.
    /// Driven by `TerminalReloadFade`.
    @State private var reloadCover: Double = 0

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
                        // Covers only the terminal, not the toolbar or the status
                        // bar: the session name has to stay visible, since it's
                        // the control the user just clicked.
                        .terminalReloadCover(reloadCover)
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
            // LEFT: the sidebar toggle is auto-injected by NavigationSplitView
            // at the standard spot (after the traffic lights). Everything else
            // goes in `.primaryAction`, which trail-aligns to the right edge of
            // the detail toolbar — matching the reference app. `.fixed` spacers
            // (macOS 26) break the shared glass so QR and the name get their own
            // pills.
            ToolbarItem(placement: .primaryAction) { serversToolbarButton }
            ToolbarItem(placement: .primaryAction) { wandToolbarButton }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) { qrToolbarButton }
                if let id = coordinator.activeSessionId {
                    // Own pill, separated from QR. On macOS 26 the toolbar wraps
                    // the item in its own glass, so DON'T draw a second inner
                    // background (that nested pill left a visible gap) — pass
                    // badged: false and let the system glass be the pill.
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
                        sessionNameLabel(id: id, badged: false)
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) { qrToolbarButton }
                if let id = coordinator.activeSessionId {
                    ToolbarItem(placement: .primaryAction) {
                        sessionNameLabel(id: id, badged: true)
                    }
                }
            }
        }
        .toolbarBackground(.black, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .focusedValue(\.sidebarVisibility, $columnVisibility)
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
        .alert(
            "Session Moved",
            isPresented: Binding(
                get: { coordinator.activityCoordinator.showSessionStolen },
                set: { coordinator.activityCoordinator.showSessionStolen = $0 }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if let name = coordinator.activityCoordinator.stolenSessionName,
               let shortId = coordinator.activityCoordinator.stolenSessionShortId {
                Text("\(name) (\(shortId)) was attached from another device.")
            }
        }
    }

    // MARK: - Toolbar Item Contents

    private var serversToolbarButton: some View {
        Button {
            NotificationCenter.default.post(name: .showServerList, object: nil)
        } label: {
            Label("Servers", systemImage: "server.rack")
        }
    }

    private var wandToolbarButton: some View {
        WandButton(
            coordinator: coordinator,
            shareScreen: settings.shareScreenWithOptimizer,
            size: 26,
            fill: Color.gray.opacity(0.5)
        )
    }

    private var qrToolbarButton: some View {
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

    /// Session-name badge (matches iOS/Android). Click → ask the server to
    /// SIGWINCH the session's foreground process group so the running app
    /// re-emits its screen (fresh bytes, not a repaint of the possibly-stale
    /// local grid), plus the swipe flash. Right-click → rename.
    ///
    /// We deliberately do NOT post `.terminalForceRedraw` here: a local repaint
    /// paints the current (stale) buffer immediately, then the SIGWINCH reply
    /// repaints with genuinely fresh bytes a round-trip later — two paints that
    /// differ slightly, which reads as a flicker. The SIGWINCH re-emit is the
    /// authoritative refresh on its own.
    ///
    /// The pill sizes to the session name (no fixed width) — it grows and
    /// shrinks with the text, capped so a very long name truncates instead of
    /// shoving the toolbar. `badged` keeps the manual pill (used on all OS
    /// versions here so the label always reads as a tappable chip).
    @ViewBuilder
    private func sessionNameLabel(id: UUID, badged: Bool) -> some View {
        Text(coordinator.name(for: id))
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)   // size to text
            // Only horizontal padding — let the toolbar drive the vertical
            // metric so the pill matches the adjacent glass icon group's height
            // instead of an over-tall hand-set frame. Capsule matches the
            // group's rounding.
            .padding(.horizontal, 10)
            .frame(maxWidth: 260)                            // truncate, don't shove
            .background(badged ? Color.white.opacity(0.12) : Color.clear)
            .clipShape(Capsule())
            .onTapGesture {
                Task {
                    await TerminalReloadFade.run(
                        coordinator: coordinator, id: id, cover: $reloadCover)
                }
            }
            .contextMenu {
                Button("Rename Session…") {
                    renameText = coordinator.name(for: id)
                    showRenameAlert = true
                }
            }
            .help("Click to reload from server · right-click to rename")
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

