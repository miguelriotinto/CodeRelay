import SwiftUI
import CodeRelayClient
import CodeRelayKit

/// Sidebar content for the workspace: one collapsible section per server
/// (spec §8.1/§8.2), each holding the unchanged workspace tiles and session
/// rows of that server. Tapping a row calls `hub.select(ref)`.
struct SessionSidebarView: View {
    @ObservedObject var hub: IOSServerHub
    @State private var showAttachSheet = false
    @State private var attachableSessions: [SessionInfo] = []
    @State private var isLoadingAttachable = false
    @State private var showQRSheet = false
    @State private var qrRef: SessionRef?

    struct Row: Equatable {
        let ref: SessionRef
        let session: SessionInfo
        let isCached: Bool
    }

    enum RetryAction: Equatable { case recover, openManagement }

    /// Flattened rows in sidebar order, skipping collapsed sections. Pure, for
    /// tests and for parity with `ServerHub.orderedRefs`.
    static func rows(for sections: [ServerSection]) -> [Row] {
        sections.flatMap { section -> [Row] in
            guard !section.isCollapsed else { return [] }
            return section.sessions.map {
                Row(ref: SessionRef(serverId: section.id, sessionId: $0.id), session: $0, isCached: section.isCached)
            }
        }
    }

    /// The "Connecting…" indicator is for a connection in progress only — never
    /// for a rejected token or an offline server, which have their own headers.
    static func isConnecting(_ sections: [ServerSection]) -> Bool {
        sections.contains { $0.config.enabled && ($0.status == .connecting || $0.status == .reconnecting) }
    }

    /// A rejected token is fixed on the management screen (Re-pair); anything
    /// else is a recovery of that one server.
    static func retryAction(for section: ServerSection) -> RetryAction {
        if case .authFailed = section.status { return .openManagement }
        return .recover
    }

    var body: some View {
        List {
            Section {
                if let focus = hub.focusCoordinator {
                    Button {
                        isLoadingAttachable = true
                        Task {
                            attachableSessions = await focus.fetchAttachableSessions()
                            isLoadingAttachable = false
                            showAttachSheet = true
                        }
                    } label: {
                        Label("Attach Session", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(isLoadingAttachable)
                }
                Button {
                    hub.isShowingServerList = true
                } label: {
                    Label("Servers", systemImage: "server.rack")
                }
            }
            .listSectionSpacing(20)

            ForEach(hub.sections) { section in
                Section {
                    ServerSectionHeader(
                        model: ServerSectionHeaderModel(section: section),
                        isCollapsed: section.isCollapsed,
                        onToggle: { hub.setCollapsed(section.id, !section.isCollapsed) },
                        onRetry: {
                            switch Self.retryAction(for: section) {
                            case .openManagement: hub.isShowingServerList = true
                            case .recover: hub.triggerUserRecovery(serverId: section.id)
                            }
                        },
                        onNew: section.status.isLive ? { Task { await hub.createSession(on: section.id) } } : nil)
                    .listRowSeparator(.hidden)
                }
                if !section.isCollapsed, let coordinator = hub.slot(for: section.id) {
                    ServerSessionRows(hub: hub, coordinator: coordinator, section: section,
                                      onShareQR: { ref in qrRef = ref; showQRSheet = true })
                } else if !section.isCollapsed, !section.sessions.isEmpty {
                    // Disabled or token-less bookmark with cached rows: plain, greyed, inert.
                    Section {
                        ForEach(section.sessions, id: \.id) { s in
                            Text(s.name ?? String(s.id.uuidString.prefix(8))).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        // Pinned, not inherited: the tiles get their rounded corners from the
        // inset-grouped section shape this style clips row backgrounds to (see
        // `WorkspaceTileBackground`). That style is only the *implicit* default in
        // the iPhone sheet; on iPad the implicit style is `.sidebar`, which does
        // no such clipping.
        .listStyle(.insetGrouped)
        .listSectionSpacing(WorkspaceTileMetrics.tileGap)
        .navigationTitle("Sessions")
        .sheet(isPresented: $showQRSheet) {
            if let ref = qrRef, let coordinator = hub.slot(for: ref.serverId) {
                QRCodeSheet(sessionId: ref.sessionId,
                            sessionName: coordinator.name(for: ref.sessionId),
                            serverInstanceId: hub.sections.first { $0.id == ref.serverId }?.config.instanceId)
            }
        }
        // Pull-to-refresh fans the wake transition out to every server, so it
        // doubles as the user's retry affordance.
        .refreshable { await hub.handleForegroundTransition(userInitiated: true) }
        .overlay {
            if Self.isConnecting(hub.sections), hub.aggregate.liveServers == 0,
               hub.sections.allSatisfy({ $0.sessions.isEmpty }) {
                ProgressView("Connecting…")
            }
        }
        .sheet(isPresented: $showAttachSheet) {
            if let focus = hub.focusCoordinator {
                AttachSessionSheet(sessions: attachableSessions, coordinator: focus, hub: hub, isPresented: $showAttachSheet)
            }
        }
    }
}

/// One server's rows: the workspace tiles and session rows exactly as the
/// single-server sidebar drew them. Rows at half opacity when the section is
/// cached (offline). Tap → `hub.select(ref)`; swipe → terminate on that server.
private struct ServerSessionRows: View {
    @ObservedObject var hub: IOSServerHub
    @ObservedObject var coordinator: SessionCoordinator
    let section: ServerSection
    let onShareQR: (SessionRef) -> Void
    @State private var collapse = SidebarCollapseModel()

    var body: some View {
        let sessions = section.sessions
        let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        ForEach(coordinator.activityCoordinator.rollups(for: sessions)) { group in
            let members = group.sessionIds.compactMap { byId[$0] }
            let collapsed = collapse.isCollapsed(group.id) || members.isEmpty
            Section {
                WorkspaceTileHeader(group: group, isCollapsed: collapsed) {
                    collapse.toggle(group.id)
                    coordinator.saveCollapsedGroups(collapse.collapsedGroupIds)  // F3
                }
                .workspaceTileRow(collapsed ? .only : .top)
                if !collapsed {
                    ForEach(Array(members.enumerated()), id: \.element.id) { index, session in
                        let ref = SessionRef(serverId: section.id, sessionId: session.id)
                        SessionRow(
                            session: session,
                            name: coordinator.name(for: session.id),
                            isActive: hub.activeRef == ref,
                            activity: coordinator.activityState(for: session.id),
                            agentId: coordinator.activeAgent(for: session.id),
                            agentState: coordinator.agentState(for: session.id),
                            seen: !coordinator.isUnseen(session.id),
                            onRename: { newName in coordinator.setName(newName, for: session.id) },
                            onShareQR: { onShareQR(ref) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await hub.select(ref) } }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await coordinator.terminateSession(id: session.id) }
                            } label: { Label("Kill", systemImage: "xmark.circle") }
                        }
                        .workspaceTileRow(.forSession(index: index, of: members.count))
                        .opacity(section.isCached ? 0.5 : 1)
                    }
                }
            }
        }
        .onAppear { collapse = SidebarCollapseModel(collapsed: coordinator.loadCollapsedGroups()) }
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: SessionInfo
    let name: String
    let isActive: Bool
    let activity: ActivityState
    let agentId: String?
    let agentState: AgentDetectedState?
    let seen: Bool
    let onRename: (String) -> Void
    let onShareQR: () -> Void

    @State private var showRenameAlert = false
    @State private var editedName = ""

    /// Spoken row summary: session name, then agent and state when one is running.
    private var accessibilityDescription: String {
        guard let friendly = AgentDisplayName.friendly(agentId), let agentState else { return name }
        return "\(name), \(friendly), \(AgentStatePillModel.word(agentState))"
    }

    var body: some View {
        HStack(spacing: 8) {
            // Regular weight against the header's bold: at the same size, the
            // old medium-vs-semibold pairing was too fine a distinction to mark
            // the group/session hierarchy, so every line read as a peer.
            Text(name)
                .font(.system(.subheadline, design: .rounded, weight: .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                // Yields to the dot so a long name truncates rather than pushing
                // the status dot out of the row.
                .layoutPriority(-1)

            // Trails the name for the same reason as the tile header's dot: a
            // shared leading dot column flattened the hierarchy.
            SessionStatusDot(state: session.state, size: 8)

            Spacer(minLength: 4)

            // The agent's *name* is deliberately not shown: with the dot, name,
            // sparkle, agent name and state pill all competing, session names
            // truncated to "Claude…" on an iPad sidebar. The sparkle already
            // identifies the agent (it is colour-coded per agent), so the text
            // was redundant with the element it sat next to.
            if let agentId, let agentState {
                AgentSparkleIcon(agentId: agentId, agentState: agentState)
                AgentStatePill(agentState: agentState, agentId: agentId, seen: seen)
            }
        }
        // The sparkle conveys the agent by colour alone and is
        // `accessibilityHidden`, so with the name text gone the agent would be
        // invisible to VoiceOver. Fold it into one spoken label instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .contextMenu {
            Button {
                editedName = name
                showRenameAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                onShareQR()
            } label: {
                Label("Share QR Code", systemImage: "qrcode")
            }
        }
        .alert("Rename Session", isPresented: $showRenameAlert) {
            TextField("Name", text: $editedName)
            Button("Rename") {
                let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { onRename(trimmed) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .selectAllOnBeginEditing(while: showRenameAlert)
    }
}

// MARK: - Attach Session Sheet

private struct AttachSessionSheet: View {
    let sessions: [SessionInfo]
    let coordinator: SessionCoordinator
    let hub: IOSServerHub
    @Binding var isPresented: Bool
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if sessions.isEmpty {
                        ContentUnavailableView(
                            "No Sessions Available",
                            systemImage: "terminal",
                            description: Text("There are no other sessions running on the server.")
                        )
                    } else {
                        List(sessions, id: \.id) { session in
                            Button {
                                isPresented = false
                                Task { await coordinator.attachRemoteSession(id: session.id, serverName: session.name) }
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.name ?? coordinator.name(for: session.id))
                                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                                            .lineLimit(1)

                                        Text(String(session.id.uuidString.prefix(8)))
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }

                                    Spacer()

                                    Text(session.state.rawValue)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(attachBadgeColor(session.state).opacity(0.15))
                                        .foregroundStyle(attachBadgeColor(session.state))
                                        .clipShape(Capsule())
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }

                Divider()

                Button {
                    showScanner = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Attach Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet(hub: hub, isAttachSheetPresented: $isPresented, isScannerPresented: $showScanner)
            }
        }
        .presentationDetents([.medium])
    }

    private func attachBadgeColor(_ state: SessionState) -> SwiftUI.Color {
        switch state {
        case .activeAttached, .activeDetached: return .green
        case .created, .starting, .resuming: return .yellow
        case .exited, .failed, .terminated, .expired: return .red
        }
    }
}

// MARK: - QR Scanner Sheet

private struct QRScannerSheet: View {
    let hub: IOSServerHub
    @Binding var isAttachSheetPresented: Bool
    @Binding var isScannerPresented: Bool

    var body: some View {
        NavigationStack {
            QRScannerView { scannedValue in
                handleScannedCode(scannedValue)
            }
            .ignoresSafeArea()
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isScannerPresented = false }
                }
            }
        }
    }

    private func handleScannedCode(_ value: String) {
        guard let link = SessionDeepLink(string: value) else {
            return  // Invalid QR code — silently ignore, keep scanning
        }

        isScannerPresented = false
        isAttachSheetPresented = false
        // Through the hub, so a `?server=` in the code routes to that relay
        // (spec §10) and a missing session surfaces as the hub's notice.
        Task { _ = await hub.handleDeepLink(link) }
    }
}
