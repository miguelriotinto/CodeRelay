import SwiftUI
import CodeRelayClient
import CodeRelayKit

/// One collapsible section per bookmark (spec §8.1/§8.3); inside each, the
/// unchanged workspace tiles and session rows for that server.
struct HubSidebarView: View {
    @ObservedObject var hub: MacServerHub
    @State private var attachTarget: IdentifiedServer?

    struct Row: Equatable {
        let ref: SessionRef
        let session: SessionInfo
        let isCached: Bool
    }

    struct IdentifiedServer: Identifiable { let id: UUID }

    /// Flattened rows in sidebar order, skipping collapsed sections. Pure, for
    /// tests and for keyboard navigation parity with `ServerHub.orderedRefs`.
    static func rows(for sections: [ServerSection]) -> [Row] {
        sections.flatMap { section -> [Row] in
            guard !section.isCollapsed else { return [] }
            return section.sessions.map {
                Row(ref: SessionRef(serverId: section.id, sessionId: $0.id), session: $0, isCached: section.isCached)
            }
        }
    }

    private var selection: Binding<SessionRef?> {
        Binding(get: { hub.activeRef }, set: { ref in if let ref { Task { await hub.select(ref) } } })
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                ForEach(hub.sections) { section in
                    Section {
                        ServerSectionHeader(
                            model: ServerSectionHeaderModel(section: section),
                            isCollapsed: section.isCollapsed,
                            onToggle: { hub.setCollapsed(section.id, !section.isCollapsed) },
                            onRetry: {
                                if case .authFailed = section.status {
                                    hub.isShowingServerList = true
                                } else {
                                    hub.triggerUserRecovery(serverId: section.id)
                                }
                            },
                            onNew: section.status.isLive ? { Task { await hub.createSession(on: section.id) } } : nil)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                        if !section.isCollapsed, let coordinator = hub.slot(for: section.id) {
                            ServerSessionRows(coordinator: coordinator, section: section)
                        } else if !section.isCollapsed, !section.sessions.isEmpty {
                            // Disabled or token-less bookmark with cached rows: plain, greyed.
                            ForEach(section.sessions, id: \.id) { s in
                                Text(s.name ?? String(s.id.uuidString.prefix(8)))
                                    .foregroundStyle(.secondary)
                                    .selectionDisabled()   // nothing can attach here
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Button {
                    hub.isShowingServerList = true
                } label: {
                    Label("Servers", systemImage: "server.rack")
                }
                .buttonStyle(.plain)

                Spacer()

                if let focusId = hub.focusServerId {
                    Button {
                        attachTarget = IdentifiedServer(id: focusId)
                    } label: {
                        Label("Attach", systemImage: "rectangle.connected.to.line.below")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .background(.black)
        .sheet(item: $attachTarget) { item in
            if let coordinator = hub.slot(for: item.id) {
                AttachRemoteSessionSheet(coordinator: coordinator)
            }
        }
    }
}
