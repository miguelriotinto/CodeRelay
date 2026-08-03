import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

/// Sidebar content for the workspace: session list with quick switching.
struct SessionSidebarView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var showAttachSheet = false
    @State private var attachableSessions: [SessionInfo] = []
    @State private var isLoadingAttachable = false
    @State private var showQRSheet = false
    @State private var qrSessionId: UUID?
    @State private var collapse = SidebarCollapseModel()

    var body: some View {
        List {
            Section {
                Button {
                    Task { await coordinator.createNewSession() }
                } label: {
                    Label("New Session", systemImage: "plus.rectangle")
                }
                Button {
                    isLoadingAttachable = true
                    Task {
                        attachableSessions = await coordinator.fetchAttachableSessions()
                        isLoadingAttachable = false
                        showAttachSheet = true
                    }
                } label: {
                    Label("Attach Session", systemImage: "arrow.triangle.branch")
                }
                .disabled(isLoadingAttachable)
            }

            if coordinator.activeSessions.isEmpty && !coordinator.isLoading {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "terminal",
                    description: Text("Create a new session to get started.")
                )
            } else {
                let sessions = coordinator.activeSessions
                let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
                ForEach(coordinator.activityCoordinator.rollups(for: sessions)) { group in
                    // Each group renders as one rounded tile. The header is a
                    // plain row rather than a Section header so it can share the
                    // tile's background; the session rows stay direct List rows
                    // so `.swipeActions` (swipe-to-kill) keeps working.
                    let members = group.sessionIds.compactMap { byId[$0] }
                    let collapsed = collapse.isCollapsed(group.id) || members.isEmpty
                    Section {
                        rollupHeader(group, isCollapsed: collapsed)
                            .workspaceTileRow(collapsed ? .only : .top)
                        if !collapsed {
                            ForEach(Array(members.enumerated()), id: \.element.id) { index, session in
                                sessionRow(session)
                                    .workspaceTileRow(.forSession(index: index, of: members.count))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sessions")
        .onAppear {
            // F3: seed collapse layout from persistence once per appear.
            collapse = SidebarCollapseModel(collapsed: coordinator.loadCollapsedGroups())
        }
        .sheet(isPresented: $showQRSheet) {
            if let sessionId = qrSessionId {
                QRCodeSheet(
                    sessionId: sessionId,
                    sessionName: coordinator.name(for: sessionId)
                )
            }
        }
        // Pull-to-refresh runs the full handshake, not a bare list fetch, so it
        // doubles as the user's retry affordance if the launch handshake failed
        // (it will reconnect and re-authenticate as needed).
        .refreshable {
            await coordinator.performHandshake(reason: .wake)
        }
        .overlay {
            if (coordinator.isLoading || coordinator.isPerformingHandshake) && coordinator.sessions.isEmpty {
                ProgressView("Loading...")
            }
        }
        .sheet(isPresented: $showAttachSheet) {
            AttachSessionSheet(
                sessions: attachableSessions,
                coordinator: coordinator,
                isPresented: $showAttachSheet
            )
        }
    }

    private func agentId(for id: UUID) -> String? {
        coordinator.activeAgent(for: id)
    }

    /// A single session row with its tap / swipe actions.
    @ViewBuilder
    private func sessionRow(_ session: SessionInfo) -> some View {
        SessionRow(
            session: session,
            name: coordinator.name(for: session.id),
            isActive: session.id == coordinator.activeSessionId,
            activity: coordinator.activityState(for: session.id),
            agentId: agentId(for: session.id),
            agentState: coordinator.agentState(for: session.id),
            seen: !coordinator.isUnseen(session.id),
            onRename: { newName in coordinator.setName(newName, for: session.id) },
            onShareQR: {
                qrSessionId = session.id
                showQRSheet = true
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await coordinator.switchToSession(id: session.id) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await coordinator.terminateSession(id: session.id) }
            } label: {
                Label("Kill", systemImage: "xmark.circle")
            }
        }
    }

    /// Collapsible tile header: rollup dot + folder title + attention count +
    /// trailing chevron. Shared with the macOS sidebar via `WorkspaceTileHeader`.
    @ViewBuilder
    private func rollupHeader(_ group: WorkspaceRollup, isCollapsed: Bool) -> some View {
        WorkspaceTileHeader(group: group, isCollapsed: isCollapsed) {
            collapse.toggle(group.id)
            coordinator.saveCollapsedGroups(collapse.collapsedGroupIds)  // F3
        }
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
            SessionStatusDot(state: session.state, size: 8)

            Text(name)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

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
    }
}

// MARK: - Attach Session Sheet

private struct AttachSessionSheet: View {
    let sessions: [SessionInfo]
    let coordinator: SessionCoordinator
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
                QRScannerSheet(coordinator: coordinator, isAttachSheetPresented: $isPresented, isScannerPresented: $showScanner)
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
    let coordinator: SessionCoordinator
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
        guard let url = URL(string: value),
              url.scheme == "clauderelay",
              url.host == "session",
              let uuidString = url.pathComponents.dropFirst().first,
              let sessionId = UUID(uuidString: uuidString) else {
            return  // Invalid QR code — silently ignore, keep scanning
        }

        isScannerPresented = false
        isAttachSheetPresented = false
        Task { await coordinator.attachRemoteSession(id: sessionId) }
    }
}
