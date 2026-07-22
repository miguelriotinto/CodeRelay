import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

struct SessionSidebarView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var renameTarget: UUID?
    @State private var renameText: String = ""
    @State private var terminateTarget: UUID?
    @State private var showAttachSheet = false

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
                    ForEach(coordinator.activeSessions, id: \.id) { session in
                        SessionRow(
                            name: coordinator.name(for: session.id),
                            state: session.state,
                            shortId: String(session.id.uuidString.prefix(8)),
                            activity: coordinator.activityState(for: session.id),
                            agentId: coordinator.activeAgent(for: session.id),
                            agentState: coordinator.agentState(for: session.id),
                            seen: !coordinator.isUnseen(session.id),
                            title: coordinator.title(for: session.id),
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
                        .tag(session.id)
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
}

private struct SessionRow: View {
    let name: String
    let state: SessionState
    let shortId: String
    let activity: ActivityState
    let agentId: String?
    let agentState: AgentDetectedState?
    let seen: Bool
    let title: String?
    let createdAt: Date

    var body: some View {
        HStack(spacing: 8) {
            SessionStatusDot(state: state, size: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(shortId)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let agentId, let friendly = AgentDisplayName.friendly(agentId), let agentState {
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
