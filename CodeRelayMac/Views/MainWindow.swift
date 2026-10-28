import SwiftUI
import CodeRelayClient
import CodeRelayKit

/// The one window. It owns the `ServerHub` (multi-server spec §7, §8.3): one
/// coordinator per enabled bookmark, one attached session across all of them.
struct MainWindow: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var hub = MacServerHubFactory.make()

    var body: some View {
        WorkspaceView(hub: hub, settings: settings)
            .background(.black)
            .task {
                ActiveCoordinatorRegistry.shared.register(hub: hub)
                await hub.start()
                await syncPush()
            }
            .onDisappear {
                hub.stop()
                ActiveCoordinatorRegistry.shared.clear()
            }
            // Wake and network-restored fan out through the hub with a stagger
            // (D10); coordinators no longer listen on their own.
            .onReceive(NotificationCenter.default.publisher(for: SleepWakeObserver.systemDidWake)) { _ in
                Task { await hub.handleForegroundTransition(userInitiated: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NetworkMonitor.connectivityRestored)) { _ in
                Task { await hub.handleForegroundTransition(userInitiated: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showServerList)) { _ in
                hub.isShowingServerList = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .connectToServer)) { notification in
                // A freshly paired bookmark is saved enabled; reloading the store
                // builds its coordinator.
                if notification.object is ConnectionConfig { hub.reloadBookmarks() }
            }
            // Re-sync push registration when APNs vends/rotates a token or the user
            // changes push settings (parity with iOS WorkspaceView).
            .onReceive(PushTokenBridge.shared.$deviceToken) { _ in Task { await syncPush() } }
            .onChange(of: settings.pushNotificationsEnabled) { _, _ in Task { await syncPush() } }
            .onChange(of: settings.pushNotifyOnFinished) { _, _ in Task { await syncPush() } }
            .preferredColorScheme(.dark)
            .focusedValue(\.sessionCoordinator, hub.activeCoordinator)
            .focusedValue(\.serverHub, hub)
    }

    /// Reconcile every enabled relay's push registration with current settings/token.
    private func syncPush() async {
        await hub.syncPushRegistration(
            pushEnabled: settings.pushNotificationsEnabled,
            notifyOnFinished: settings.pushNotifyOnFinished)
    }
}

private struct WorkspaceView: View {
    @ObservedObject var hub: MacServerHub
    @ObservedObject var settings: AppSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showQRPopover = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    /// One sheet + blackout for switch, session-name refresh and reconnect.
    @StateObject private var loading = SessionLoadingSheetModel()

    private var coordinator: SessionCoordinator? { hub.activeCoordinator }
    /// Drives the surfaces a one-server user expects even with nothing selected
    /// (Reconnecting sheet, error alerts, QR scanner, status bar) — G8.
    private var focus: SessionCoordinator? { hub.focusCoordinator }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HubSidebarView(hub: hub)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            VStack(spacing: 0) {
                detail
                Divider()
                if let focus {
                    StatusBarView(coordinator: focus)
                } else {
                    HubStatusBar(hub: hub)
                }
            }
            .background(.black)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { serversToolbarButton }
            if let coordinator {
                ToolbarItem(placement: .primaryAction) {
                    WandButton(coordinator: coordinator,
                               shareScreen: settings.shareScreenWithOptimizer,
                               size: 26, fill: Color.gray.opacity(0.5))
                }
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) { qrToolbarButton }
                if let coordinator, let id = coordinator.activeSessionId {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
                        sessionNameLabel(coordinator: coordinator, id: id, badged: false)
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) { qrToolbarButton }
                if let coordinator, let id = coordinator.activeSessionId {
                    ToolbarItem(placement: .primaryAction) {
                        sessionNameLabel(coordinator: coordinator, id: id, badged: true)
                    }
                }
            }
        }
        .toolbarBackground(.black, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .focusedValue(\.sidebarVisibility, $columnVisibility)
        // SwiftUI cannot bind a sheet through an optional, so the sheets and
        // alerts that belong to the focus coordinator (the active server, else
        // the only / first live one) live on a child view that only exists
        // while there is one (spec §8.1: the Reconnecting sheet is per server).
        .background {
            if let focus {
                ActiveCoordinatorModifiers(coordinator: focus, loading: loading,
                                           serverName: hub.sections.first { $0.id == hub.focusServerId }?.title)
                    .id(ObjectIdentifier(focus))
            }
        }
        // The one loading sheet (parity with iOS): switch, session-name refresh
        // and reconnect, with the bytes loaded as the largest text. Hosted HERE,
        // not on the re-keyed focus child, so a cross-server switch mid-load
        // does not dismiss and re-present it.
        .sheet(isPresented: Binding(get: { loading.isPresented }, set: { _ in })) {
            if let shown = loading.shown {
                SessionLoadingSheet(presentation: shown,
                                    onCancel: shown.allowsCancel ? { hub.focusCoordinator?.cancelRecovery() } : nil)
                    .frame(width: MainWindowLoading.detentSize.width, height: MainWindowLoading.detentSize.height)
                    .interactiveDismissDisabled()
            }
        }
        .sheet(isPresented: $hub.isShowingServerList) {
            NavigationStack {
                ServerListWindow(hub: hub)
            }
            .background(.black)
            .presentationBackground(.black)
        }
        .overlay(alignment: .top) {
            if let notice = hub.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        if hub.notice == notice { hub.notice = nil }
                    }
            }
        }
        .alert("Rename Session", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, let coordinator, let id = coordinator.activeSessionId {
                    coordinator.setName(trimmed, for: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let coordinator, let activeId = coordinator.activeSessionId {
            ZStack {
                // Single host reused across session switches so each
                // terminal's SwiftTerm scrollback survives the swap.
                TerminalContainerView(coordinator: coordinator, fontSize: CGFloat(settings.terminalFontSize))
                    .padding(.leading, 6)
                    // Black while the loading sheet is up; both lift on the first frame.
                    .terminalLoadingCover(loading.isPresented)
            }
            // The container is keyed by the coordinator so a cross-server switch
            // swaps the whole host; within one server the host is reused.
            .id(ObjectIdentifier(coordinator))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(emptyTitle)
                    .foregroundStyle(.secondary)
                if let serverId = firstLiveServerId {
                    Button("New Session") {
                        Task { await hub.createSession(on: serverId) }
                    }
                } else if hub.aggregate.enabledServers == 0 {
                    Button("Servers…") { hub.isShowingServerList = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var firstLiveServerId: UUID? {
        if let id = hub.activeRef?.serverId, hub.sections.contains(where: { $0.id == id && $0.status.isLive }) {
            return id
        }
        return hub.sections.first(where: { $0.status.isLive })?.id
    }

    private var emptyTitle: String {
        if hub.aggregate.enabledServers == 0 { return "No servers enabled" }
        if hub.aggregate.liveServers == 0 { return "Connecting to servers…" }
        return "No session selected"
    }

    // MARK: - Toolbar Item Contents

    private var serversToolbarButton: some View {
        Button {
            hub.isShowingServerList = true
        } label: {
            Label("Servers", systemImage: "server.rack")
        }
    }

    private var qrToolbarButton: some View {
        Button {
            showQRPopover = true
        } label: {
            Label("Share via QR Code", systemImage: "qrcode")
        }
        .disabled(coordinator?.activeSessionId == nil)
        .popover(isPresented: $showQRPopover, arrowEdge: .bottom) {
            if let coordinator, let id = coordinator.activeSessionId {
                QRCodePopover(sessionId: id, sessionName: coordinator.name(for: id))
            }
        }
    }

    /// Session-name badge (matches iOS/Android). Click → reload the terminal
    /// from the server's ring buffer; right-click → rename. See the pre-hub
    /// history of this view for why no local repaint is posted here.
    @ViewBuilder
    private func sessionNameLabel(coordinator: SessionCoordinator, id: UUID, badged: Bool) -> some View {
        Text(coordinator.name(for: id))
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .frame(maxWidth: 260)
            .background(badged ? Color.white.opacity(0.12) : Color.clear)
            .clipShape(Capsule())
            .onTapGesture {
                Task { await TerminalReloadFade.reload(coordinator: coordinator, id: id) }
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

/// Sheets and alerts bound to the active coordinator's published flags.
/// Rendered as an invisible background child so each binding is non-optional.
private struct ActiveCoordinatorModifiers: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var loading: SessionLoadingSheetModel
    let serverName: String?

    private var presentation: SessionLoadingPresentation {
        SessionLoadingPresentation(loadPhase: coordinator.sessionLoadPhase,
                                   isRecovering: coordinator.isRecovering,
                                   recoveryPhase: coordinator.recoveryPhase,
                                   expectsSession: coordinator.expectsSessionToLoad,
                                   sessionName: coordinator.activeSessionId.map { coordinator.name(for: $0) },
                                   serverName: serverName)
    }

    var body: some View {
        Color.clear
            .sheet(isPresented: $coordinator.showQRScanner) {
                QRScannerSheet(coordinator: coordinator)
            }
            .onChange(of: presentation, initial: true) { _, current in loading.update(current) }
            .alert("Cannot Open Session", isPresented: $coordinator.sessionAttachFailed) {
                Button("OK", role: .cancel) { coordinator.sessionAttachError = nil }
            } message: {
                Text(coordinator.sessionAttachError ?? "Unable to attach to this session.")
            }
            .alert("Connection Lost", isPresented: $coordinator.connectionTimedOut) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Unable to reconnect to the server. Check your network and try reconnecting.")
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
}

/// Status bar shown when no session is attached: the hub's aggregate.
private struct HubStatusBar: View {
    @ObservedObject var hub: MacServerHub

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(hub.aggregate.liveServers > 0 ? Color.green : (hub.aggregate.enabledServers > 0 ? .orange : .secondary))
                .frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.black)
    }

    private var label: String {
        let a = hub.aggregate
        if a.enabledServers == 0 { return "No servers enabled" }
        return a.enabledServers == 1
            ? (a.liveServers == 1 ? "Connected" : "Connecting…")
            : "\(a.liveServers)/\(a.enabledServers) servers connected"
    }
}

/// Size of the loading sheet as a macOS window sheet (iOS uses a detent).
enum MainWindowLoading {
    static let detentSize = CGSize(width: 320, height: 220)
}
