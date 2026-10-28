import SwiftUI
import CodeRelayClient
import CodeRelayKit

/// Pure rules the root view is built on, kept out of SwiftUI for tests.
enum WorkspaceRoot {
    /// With no enabled server there is nothing to show behind the terminal:
    /// present the management sheet (spec §8.1 "root screen is the workspace;
    /// with zero bookmarks it shows the existing add/pair empty state").
    static func shouldPresentManagement(aggregate: HubAggregate) -> Bool {
        aggregate.enabledServers == 0
    }
}

/// Main workspace over the hub: NavigationSplitView with a grouped session
/// sidebar and the active coordinator's terminal (spec §8.2).
struct WorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject var hub: IOSServerHub
    @ObservedObject private var settings = AppSettings.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showSidebarSheet = false
    /// Kept alive for the view's lifetime so `connectivityRestored` posts; the
    /// coordinators no longer arm their own monitor (the hub fans out, D10).
    @StateObject private var networkMonitor = NetworkMonitor()
    /// One sheet + blackout for switch, session-name refresh and reconnect.
    @StateObject private var loading = SessionLoadingSheetModel()

    /// Maps the sidebar button's columnVisibility toggle directly to showSidebarSheet on iPhone.
    private var sidebarSheetBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { showSidebarSheet ? .all : .detailOnly },
            set: { newValue in showSidebarSheet = (newValue == .all) }
        )
    }

    /// Reconcile every enabled relay's push registration with settings/token.
    private func syncPush() async {
        await hub.syncPushRegistration(
            pushEnabled: settings.pushNotificationsEnabled,
            notifyOnFinished: settings.pushNotifyOnFinished)
    }

    var body: some View {
        Group {
            if sizeClass == .compact {
                // iPhone: detail-only with the sidebar as a sheet
                ActiveTerminalView(hub: hub, columnVisibility: sidebarSheetBinding, loading: loading)
                    .sheet(isPresented: $showSidebarSheet) {
                        NavigationStack {
                            SessionSidebarView(hub: hub)
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button("Done") { showSidebarSheet = false }
                                    }
                                }
                        }
                        .presentationDetents([.medium, .large])
                    }
            } else {
                // iPad: full split view
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SessionSidebarView(hub: hub)
                } detail: {
                    ActiveTerminalView(hub: hub, columnVisibility: $columnVisibility, loading: loading)
                }
                .navigationSplitViewStyle(.prominentDetail)
                .navigationBarHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .task {
            await hub.start()
            await syncPush()
            if WorkspaceRoot.shouldPresentManagement(aggregate: hub.aggregate) {
                hub.isShowingServerList = true
            } else if hub.activeRef == nil {
                if sizeClass == .compact { showSidebarSheet = true } else { columnVisibility = .all }
            }
        }
        // Re-sync push registration when the OS vends/rotates a token or the
        // user changes push settings.
        .onReceive(PushTokenBridge.shared.$deviceToken) { _ in Task { await syncPush() } }
        .onChange(of: settings.pushNotificationsEnabled) { _, _ in Task { await syncPush() } }
        .onChange(of: settings.pushNotifyOnFinished) { _, _ in Task { await syncPush() } }
        .onChange(of: hub.activeRef) { _, newValue in
            if newValue != nil {
                withAnimation {
                    columnVisibility = .detailOnly
                    showSidebarSheet = false
                }
            }
        }
        .onDisappear { hub.stop() }
        // Foreground and network-restored fan out through the hub with a
        // stagger (D10); coordinators install no observers of their own.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { Task { await hub.handleForegroundTransition(userInitiated: true) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NetworkMonitor.connectivityRestored)) { _ in
            Task { await hub.handleForegroundTransition(userInitiated: true) }
        }
        // The sheets and alerts that belong to one coordinator live on a child
        // view that exists only while the focus coordinator does (the active
        // server, else the only / first live one — G8).
        .background {
            if let focus = hub.focusCoordinator {
                FocusCoordinatorModifiers(coordinator: focus, loading: loading,
                                          serverName: hub.sections.first { $0.id == hub.focusServerId }?.title)
                    .id(ObjectIdentifier(focus))
            }
        }
        .sheet(isPresented: $hub.isShowingServerList) {
            ServerListView(hub: hub)
        }
        .overlay(alignment: .top) {
            if let notice = hub.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(4))
                        if hub.notice == notice { hub.notice = nil }
                    }
            }
        }
    }
}

/// Sheets and alerts bound to one coordinator's published flags, rendered as an
/// invisible background child so each binding is non-optional.
private struct FocusCoordinatorModifiers: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var loading: SessionLoadingSheetModel
    let serverName: String?

    private var presentation: SessionLoadingPresentation {
        SessionLoadingPresentation(loadPhase: coordinator.sessionLoadPhase,
                                   isRecovering: coordinator.isRecovering,
                                   recoveryPhase: coordinator.recoveryPhase,
                                   sessionName: coordinator.activeSessionId.map { coordinator.name(for: $0) },
                                   serverName: serverName)
    }

    var body: some View {
        Color.clear
            .onChange(of: presentation, initial: true) { _, current in loading.update(current) }
            // The one loading sheet: switch, session-name refresh and reconnect
            // all rise from the bottom with the step and the bytes loaded, while
            // the terminal behind fades to black; both lift on the first frame.
            .sheet(isPresented: Binding(get: { loading.isPresented }, set: { _ in })) {
                if let shown = loading.shown {
                    SessionLoadingSheet(presentation: shown,
                                        onCancel: shown.allowsCancel ? { coordinator.cancelRecovery() } : nil)
                        .presentationDetents([.fraction(0.32)])
                        .presentationDragIndicator(.hidden)
                        .presentationBackgroundInteraction(.disabled)
                        .interactiveDismissDisabled()
                        // Full width, not the safe area: on iPhone Duo the status
                        // bar column is carved out of a sheet's safe area, which
                        // put a safe-area-centred stack ~85 pt off centre.
                        .ignoresSafeArea(.container, edges: .horizontal)
                }
            }
            .alert("Connection Lost", isPresented: $coordinator.connectionTimedOut) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Unable to reconnect to \(serverName ?? "the server"). Check your network, then pull to refresh.")
            }
            .alert("Error", isPresented: $coordinator.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(coordinator.errorMessage ?? "Unknown error")
            }
            .alert("Cannot Open Session", isPresented: $coordinator.sessionAttachFailed) {
                Button("OK", role: .cancel) { coordinator.sessionAttachError = nil }
            } message: {
                Text(coordinator.sessionAttachError ?? "Unable to attach to this session.")
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
