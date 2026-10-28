import SwiftUI
import CodeRelayClient

/// Server management (multi-server spec §8.1, §11): every bookmark with an
/// **Enabled** toggle. There is no Connect — enabled servers are live in the
/// workspace, disabled ones are only probed by the status poller.
struct ServerListWindow: View {
    @ObservedObject var hub: MacServerHub
    @StateObject private var viewModel = ServerListViewModel()
    @State private var addEditTarget: AddEditTarget?
    @State private var showDeleteAlert = false
    @State private var deleteTarget: ConnectionConfig?
    @State private var showPairSheet = false

    enum AddEditTarget: Identifiable {
        case add
        case edit(ConnectionConfig)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let c): return c.id.uuidString
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedConnectionId) {
                ForEach(hub.sections) { section in
                    ServerRow(
                        section: section,
                        probe: viewModel.statuses[section.id],
                        onToggle: { on in
                            // A refusal (cap of 8) leaves `hub.notice` for the footer.
                            _ = hub.setEnabled(section.id, on)
                            viewModel.loadConnections()
                        }
                    )
                    .contextMenu {
                        Button("Edit...") { addEditTarget = .edit(section.config) }
                        Divider()
                        Button("Delete", role: .destructive) {
                            deleteTarget = section.config
                            showDeleteAlert = true
                        }
                    }
                    .tag(section.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            if let notice = hub.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            Divider()
            HStack {
                Button {
                    addEditTarget = .add
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                Button {
                    showPairSheet = true
                } label: {
                    Label("Pair", systemImage: "qrcode")
                }
                Spacer()
                Text("\(hub.aggregate.enabledServers) of \(hub.aggregate.totalServers) enabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .background(.black)
        .frame(minWidth: 520, minHeight: 360)
        // Stop the status poll as soon as the sheet closes (see ServerStatusChecker.deinit).
        .onDisappear { viewModel.stopAllPolling() }
        .navigationTitle("Servers")
        .toolbarBackground(.black, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .sheet(item: $addEditTarget) { target in
            AddEditServerView(target: target) { newConnection in
                viewModel.addOrUpdate(newConnection)
                hub.reloadBookmarks()
                addEditTarget = nil
            }
        }
        .sheet(isPresented: $showPairSheet) {
            PairWithHostSheet(
                onPaired: { config in
                    viewModel.addOrUpdate(config)      // paired bookmarks are saved enabled
                    hub.reloadBookmarks()
                },
                prefill: nil
            )
        }
        .alert("Delete Server?", isPresented: $showDeleteAlert, presenting: deleteTarget) { target in
            Button("Delete", role: .destructive) {
                Task {
                    await hub.removeServer(target.id)
                    viewModel.loadConnections()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("Are you sure you want to delete '\(target.name)'?")
        }
    }
}

private struct ServerRow: View {
    let section: ServerSection
    let probe: ServerStatus?
    let onToggle: (Bool) -> Void

    private var model: ServerSectionHeaderModel { ServerSectionHeaderModel(section: section) }

    private var dotColor: Color {
        if section.config.enabled { return model.dotColor }
        guard let probe else { return .gray }
        if probe.reachability == .invalidToken { return .orange }
        return probe.isLive ? .green : .red
    }

    var body: some View {
        HStack {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(section.title).font(.headline)
                    if section.isDuplicateInstance {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help("Another bookmark points at this same relay")
                    }
                }
                Text("\(section.config.useTLS ? "wss" : "ws")://\(section.config.host):\(section.config.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let subtitle = model.subtitle, section.config.enabled {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let instance = section.config.instanceId {
                    Text("instance \(instance.uuidString.prefix(8))…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { section.config.enabled }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(section.config.enabled ? "Shown in the workspace" : "Enable to show this server's sessions")
        }
        .padding(.vertical, 4)
    }
}
