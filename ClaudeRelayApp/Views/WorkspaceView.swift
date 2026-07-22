import SwiftUI
import ClaudeRelayClient

// MARK: - Recovery Overlay (shown during in-session reconnection)

struct RecoveryOverlay: View {
    let phase: SharedSessionCoordinator.RecoveryPhase
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text("Reconnecting")
                .font(.headline)

            Text(phase.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: phase.label)

            Spacer()

            Button("Cancel", role: .cancel) {
                onCancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// Main workspace: NavigationSplitView with a session sidebar and terminal detail.
struct WorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var coordinator: SessionCoordinator
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showSidebarSheet = false
    @Environment(\.dismiss) private var dismiss
    private let pendingAttachSessionId: UUID?

    init(connection: RelayConnection, token: String, pendingAttachSessionId: UUID? = nil) {
        self.pendingAttachSessionId = pendingAttachSessionId
        _coordinator = StateObject(wrappedValue: SessionCoordinator(
            connection: connection,
            token: token
        ))
    }

    /// Maps the sidebar button's columnVisibility toggle directly to showSidebarSheet on iPhone.
    private var sidebarSheetBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { showSidebarSheet ? .all : .detailOnly },
            set: { newValue in showSidebarSheet = (newValue == .all) }
        )
    }

    /// Reconcile this device's push registration with current settings/token.
    private func syncPush() async {
        await coordinator.syncPushRegistration(
            pushEnabled: AppSettings.shared.pushNotificationsEnabled,
            notifyOnFinished: AppSettings.shared.pushNotifyOnFinished)
    }

    var body: some View {
        Group {
            if sizeClass == .compact {
                // iPhone: detail-only with sidebar as a sheet
                ActiveTerminalView(
                    coordinator: coordinator,
                    columnVisibility: sidebarSheetBinding,
                    onDisconnect: { dismiss() }
                )
                .sheet(isPresented: $showSidebarSheet) {
                    NavigationStack {
                        SessionSidebarView(coordinator: coordinator)
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
                    SessionSidebarView(coordinator: coordinator)
                } detail: {
                    ActiveTerminalView(
                        coordinator: coordinator,
                        columnVisibility: $columnVisibility,
                        onDisconnect: { dismiss() }
                    )
                }
                .navigationSplitViewStyle(.prominentDetail)
                .navigationBarHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .task {
            coordinator.startNetworkRecovery()
            if let sessionId = pendingAttachSessionId {
                await coordinator.attachRemoteSession(id: sessionId)
            }
            await coordinator.fetchSessions()
            await syncPush()
            if coordinator.activeSessionId == nil {
                if sizeClass == .compact {
                    showSidebarSheet = true
                } else {
                    columnVisibility = .all
                }
            }
        }
        // Re-sync push registration when the OS vends/rotates a token or the
        // user changes push settings.
        .onReceive(PushTokenBridge.shared.$deviceToken) { _ in
            Task { await syncPush() }
        }
        .onChange(of: AppSettings.shared.pushNotificationsEnabled) { _, _ in
            Task { await syncPush() }
        }
        .onChange(of: AppSettings.shared.pushNotifyOnFinished) { _, _ in
            Task { await syncPush() }
        }
        .onChange(of: coordinator.activeSessionId) { _, newValue in
            if newValue != nil {
                withAnimation {
                    columnVisibility = .detailOnly
                    showSidebarSheet = false
                }
            }
        }
        .onDisappear {
            coordinator.tearDown()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                coordinator.triggerUserRecovery()
            }
        }
        .sheet(isPresented: $coordinator.isRecovering) {
            RecoveryOverlay(
                phase: coordinator.recoveryPhase,
                onCancel: {
                    coordinator.cancelRecovery()
                }
            )
            .interactiveDismissDisabled()
        }
        .alert("Connection Timed Out",
               isPresented: Binding(
                   get: { coordinator.connectionTimedOut },
                   set: { newValue in
                       if !newValue {
                           coordinator.connectionTimedOut = false
                       }
                   })) {
            Button("OK", role: .cancel) {
                dismiss()
            }
        } message: {
            Text("Connection timed out. Please reconnect.")
        }
        .alert("Error", isPresented: $coordinator.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.errorMessage ?? "Unknown error")
        }
        .alert("Cannot Open Session", isPresented: $coordinator.sessionAttachFailed) {
            Button("OK", role: .cancel) {
                coordinator.sessionAttachError = nil
            }
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
