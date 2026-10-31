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

/// Whether a one-finger drag is the left-edge swipe that opens the session list
/// (docs/superpowers/specs/2026-10-31-edge-swipe-sessions.md). Points, in the
/// strip's own space (x from the left edge). The Kotlin twin is
/// `relay.feature.workspace.EdgeSwipeLogic`; keep the numbers in step.
enum EdgeSwipeRule {
    /// Width of the start strip along the left edge.
    static let stripWidth: CGFloat = 20
    /// Minimum rightward travel.
    static let minTravel: CGFloat = 40
    /// Horizontal travel must exceed this multiple of the vertical travel.
    static let horizontalDominance: CGFloat = 2

    static func shouldOpen(startX: CGFloat, dx: CGFloat, dy: CGFloat, listOpen: Bool) -> Bool {
        !listOpen
            && startX >= 0 && startX <= stripWidth
            && dx >= minTravel
            && abs(dx) > horizontalDominance * abs(dy)
    }
}

/// Main workspace over the hub: NavigationSplitView with a grouped session
/// sidebar and the active coordinator's terminal (spec §8.2).
struct WorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject var hub: IOSServerHub
    /// A pairing link from the App (Camera scan / `coderelay://pair`). Presented
    /// here, or handed to the management sheet while that is up — a second sheet
    /// on the same presenter would be queued behind one that cannot close.
    @Binding var pendingPairing: PairingURL?
    @ObservedObject private var settings = AppSettings.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showSidebarSheet = false
    /// A pairing link handed to the management sheet (see `onChange(of: pendingPairing)`).
    @State private var managementPairing: PairingURL?
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

    private enum PresentedSheet { case management, sidebar, pairing, loading }

    /// The sheet the user is looking at, if any. The sidebar steps aside for
    /// management and loading; a pairing link queues behind the sidebar.
    private var topmostSheet: PresentedSheet? {
        if hub.isShowingServerList { return .management }
        if showSidebarSheet && sizeClass == .compact { return .sidebar }
        if pendingPairing != nil { return .pairing }
        if loading.isPresented { return .loading }
        return nil
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
                        .sessionLossAlert(hub.takenAlert, isTopmost: topmostSheet == .sidebar, onOK: { hub.dismissTakenAlert() })
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
            #if DEBUG
            // `CODERELAY_LOADING_PREVIEW=reconnecting|history` holds the loading
            // sheet up over the empty pane for screenshot verification.
            if let preview = LoadingSheetPreview.presentation {
                showSidebarSheet = false
                columnVisibility = .detailOnly
                loading.update(preview)
                return
            }
            #endif
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
        // The alerts that belong to one coordinator live on a child view that
        // exists only while the focus coordinator does (the active server, else
        // the only / first live one — G8); it also FEEDS the loading model.
        .background {
            if let focus = hub.focusCoordinator {
                FocusCoordinatorModifiers(coordinator: focus, loading: loading,
                                          serverName: hub.sections.first { $0.id == hub.focusServerId }?.title)
                    .id(ObjectIdentifier(focus))
            }
        }
        // iOS presents one sheet per presenter: the sidebar sheet (compact), the
        // management sheet and the loading sheet all hang off this view, so the
        // sidebar steps aside the moment either of the others is wanted.
        .onChange(of: hub.isShowingServerList) { _, showing in if showing { showSidebarSheet = false } }
        .onChange(of: loading.isPresented) { _, presented in if presented { showSidebarSheet = false } }
        .onChange(of: pendingPairing) { _, pairing in
            // While management is up (and un-dismissable with nothing enabled) it
            // takes the link, so a Camera scan on first run still pairs.
            if pairing != nil, hub.isShowingServerList { managementPairing = pairing; pendingPairing = nil }
        }
        .sheet(isPresented: $hub.isShowingServerList) {
            ServerListView(hub: hub, externalPairing: $managementPairing)
                .sessionLossAlert(hub.takenAlert, isTopmost: topmostSheet == .management, onOK: { hub.dismissTakenAlert() })
        }
        .sheet(item: Binding(get: { hub.isShowingServerList ? nil : pendingPairing },
                             set: { pendingPairing = $0 })) { pairing in
            PairWithHostSheet(onPaired: { _ in
                // The paired bookmark is saved enabled; reloading builds its
                // coordinator (the cap is enforced by the hub).
                hub.reloadBookmarks()
            }, prefill: pairing)
            .sessionLossAlert(hub.takenAlert, isTopmost: topmostSheet == .pairing, onOK: { hub.dismissTakenAlert() })
        }
        // The one loading sheet: switch, session-name refresh and reconnect all
        // rise from the bottom with the step and the bytes loaded, while the
        // terminal behind fades to black; both lift on the first frame. Hosted
        // HERE, not on the re-keyed focus child, so a cross-server switch
        // mid-load does not dismiss and re-present it.
        .sheet(isPresented: Binding(get: { loading.isPresented && !showSidebarSheet && !hub.isShowingServerList },
                                    set: { _ in })) {
            if let shown = loading.shown {
                SessionLoadingSheet(presentation: shown,
                                    onCancel: shown.allowsCancel ? { hub.focusCoordinator?.cancelRecovery() } : nil)
                    // Exactly as tall as its content, never a fixed fraction:
                    // with the reconnect Cancel a third of a short landscape or
                    // iPhone Duo display clipped the spinner and the button.
                    .sessionLoadingSheetContainer()
                    .presentationDragIndicator(.hidden)
                    .presentationBackgroundInteraction(.disabled)
                    .interactiveDismissDisabled()
                    // Full width, not the safe area: on iPhone Duo the status
                    // bar column is carved out of a sheet's safe area, which
                    // put a safe-area-centred stack ~85 pt off centre.
                    .ignoresSafeArea(.container, edges: .horizontal)
                    .sessionLossAlert(hub.takenAlert, isTopmost: topmostSheet == .loading, onOK: { hub.dismissTakenAlert() })
            }
        }
        .overlay(alignment: .top) {
            if let notice = hub.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // The 4 s start only once the session-loss alert is gone,
                    // or the pill would expire unseen behind it.
                    .task(id: hub.takenAlert == nil ? notice : nil) {
                        guard hub.takenAlert == nil else { return }
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
                        if hub.notice == notice { hub.notice = nil }
                    }
            }
        }
        // Session loss belongs to the hub, never to the focus coordinator. The
        // root copy is live only with no sheet up; each sheet carries its own.
        .sessionLossAlert(hub.takenAlert, isTopmost: topmostSheet == nil, onOK: { hub.dismissTakenAlert() })
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
                                   // The handshake narrates a server, not a session, unless one is
                                   // attached or about to be restored.
                                   expectsSession: coordinator.expectsSessionToLoad,
                                   sessionAttached: coordinator.activeSessionId != nil,
                                   loadFailed: coordinator.loadEndedInFailure,
                                   recoveryFailed: coordinator.recoveryFailed,
                                   sessionName: coordinator.activeSessionId.map { coordinator.name(for: $0) },
                                   serverName: serverName)
    }

    var body: some View {
        Color.clear
            .onChange(of: presentation, initial: true) { _, current in loading.update(current) }
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
    }
}
