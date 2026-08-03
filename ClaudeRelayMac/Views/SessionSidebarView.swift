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
                        // One rounded tile per group. The header is a plain row
                        // (not a Section header) so it shares the tile
                        // background; `selectionDisabled` keeps it out of the
                        // List's selection, which drives session switching.
                        let members = group.sessionIds.compactMap { byId[$0] }
                        let collapsed = collapse.isCollapsed(group.id) || members.isEmpty
                        Section {
                            rollupHeader(group, isCollapsed: collapsed)
                                .workspaceTileRow(collapsed ? .only : .top)
                                .selectionDisabled()
                            if !collapsed {
                                ForEach(Array(members.enumerated()), id: \.element.id) { index, session in
                                    sessionRow(session)
                                        .tag(session.id)
                                        .workspaceTileRow(.forSession(index: index, of: members.count))
                                }
                            }
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

    /// Collapsible tile header: rollup dot + folder title + attention count +
    /// trailing chevron. Shared with the iOS sidebar via `WorkspaceTileHeader`.
    @ViewBuilder
    private func rollupHeader(_ group: WorkspaceRollup, isCollapsed: Bool) -> some View {
        WorkspaceTileHeader(
            group: group,
            isCollapsed: isCollapsed,
            titleFont: .caption.weight(.semibold)
        ) {
            collapse.toggle(group.id)
            coordinator.saveCollapsedGroups(collapse.collapsedGroupIds)  // F3
        }
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

    /// Spoken row summary: session name, then agent and state when one is running.
    private var accessibilityDescription: String {
        guard let friendly = AgentDisplayName.friendly(agentId), let agentState else { return name }
        return "\(name), \(friendly), \(AgentStatePillModel.word(agentState))"
    }

    var body: some View {
        HStack(spacing: 8) {
            SessionStatusDot(state: state, size: 6)
            Text(name).font(.body).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            // Agent *name* omitted for parity with iOS: dot + name + sparkle +
            // agent name + pill left no room for the session name in a narrow
            // sidebar, and the colour-coded sparkle already identifies the agent.
            if let agentId, let agentState {
                AgentSparkleIcon(agentId: agentId, agentState: agentState)
                AgentStatePill(agentState: agentState, agentId: agentId, seen: seen)
            }
        }
        // The sparkle is `accessibilityHidden` and colour-only, so fold the agent
        // identity into the row's spoken label now that the text is gone.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }
}
