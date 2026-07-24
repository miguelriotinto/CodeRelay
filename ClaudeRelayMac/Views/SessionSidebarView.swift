import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

struct SessionSidebarView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var renameTarget: UUID?
    @State private var renameText: String = ""
    @State private var terminateTarget: UUID?
    @State private var showAttachSheet = false
    @State private var collapse = SidebarCollapseModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(selection: Binding(
                    get: { coordinator.activeSessionId },
                    set: { newId in
                        if let id = newId {
                            Task { await coordinator.switchToSession(id: id) }
                        }
                    }
                )) {
                    let sessions = coordinator.activeSessions
                    let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
                    ForEach(coordinator.activityCoordinator.rollups(for: sessions)) { group in
                        Section {
                            if !collapse.isCollapsed(group.id) {
                                ForEach(group.sessionIds.compactMap { byId[$0] }, id: \.id) { session in
                                    sessionRow(session).tag(session.id)
                                }
                            }
                        } header: {
                            rollupHeader(group)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                // SwiftUI's default List(selection:) auto-scroll on selection
                // change can place the selected row partially under the window
                // titlebar on macOS. Re-anchor it to the vertical center after
                // the built-in scroll settles so the row lands fully visible.
                .onChange(of: coordinator.activeSessionId) { _, newId in
                    guard let newId else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(newId, anchor: .center)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button {
                    Task { await coordinator.createNewSession() }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    showAttachSheet = true
                } label: {
                    Label("Attach", systemImage: "rectangle.connected.to.line.below")
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
        .background(.black)
        .onAppear {
            // F3: seed collapse layout from persistence once per appear.
            collapse = SidebarCollapseModel(collapsed: coordinator.loadCollapsedGroups())
        }
        .sheet(isPresented: $showAttachSheet) {
            AttachRemoteSessionSheet(coordinator: coordinator)
        }
        .alert("Rename Session", isPresented: .init(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renameTarget {
                    coordinator.setName(renameText, for: id)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Terminate Session?",
               isPresented: .init(
                get: { terminateTarget != nil },
                set: { if !$0 { terminateTarget = nil } }
               )) {
            Button("Terminate", role: .destructive) {
                if let id = terminateTarget {
                    Task { await coordinator.terminateSession(id: id) }
                }
                terminateTarget = nil
            }
            Button("Cancel", role: .cancel) { terminateTarget = nil }
        }
    }

    /// A single session row with its context menu.
    @ViewBuilder
    private func sessionRow(_ session: SessionInfo) -> some View {
        SessionRow(
            name: coordinator.name(for: session.id),
            state: session.state,
            activity: coordinator.activityState(for: session.id),
            agentId: coordinator.activeAgent(for: session.id),
            agentState: coordinator.agentState(for: session.id),
            seen: !coordinator.isUnseen(session.id),
            createdAt: session.createdAt
        )
        .contextMenu {
            Button("Rename") {
                renameText = coordinator.name(for: session.id)
                renameTarget = session.id
            }
            Divider()
            Button("Terminate", role: .destructive) {
                terminateTarget = session.id
            }
        }
    }

    /// Collapsible group header: chevron + rollup dot + title + attention count.
    @ViewBuilder
    private func rollupHeader(_ group: WorkspaceRollup) -> some View {
        Button {
            collapse.toggle(group.id)
            coordinator.saveCollapsedGroups(collapse.collapsedGroupIds)  // F3
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapse.isCollapsed(group.id) ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Circle().fill(group.state.badgeColor).frame(width: 8, height: 8)
                Text(group.title).font(.caption.weight(.semibold))
                Spacer()
                if group.attentionCount > 0 {
                    Text("\(group.attentionCount)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SessionRow: View {
    let name: String
    let state: SessionState
    let activity: ActivityState
    let agentId: String?
    let agentState: AgentDetectedState?
    let seen: Bool
    let createdAt: Date

    var body: some View {
        HStack(spacing: 8) {
            SessionStatusDot(state: state, size: 6)
            Text(name).font(.body).lineLimit(1).truncationMode(.tail)
            Spacer()
            if let agentId, let friendly = AgentDisplayName.friendly(agentId), let agentState {
                AgentSparkleIcon(agentId: agentId, agentState: agentState)
                Text(friendly)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                AgentStatePill(agentState: agentState, agentId: agentId, seen: seen)
            }
        }
        .padding(.vertical, 2)
    }
}
