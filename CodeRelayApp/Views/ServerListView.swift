import SwiftUI
import CodeRelayClient
import CodeRelayKit

/// Server management (multi-server spec §8.1, §11): every bookmark with an
/// **Enabled** toggle. There is no Connect — enabled servers are live in the
/// workspace, disabled ones are only probed by the status poller.
struct ServerListView: View {
    @ObservedObject var hub: IOSServerHub
    @StateObject private var viewModel = ServerListViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showAddSheet = false
    @State private var showSettings = false
    @State private var serverToEdit: ConnectionConfig?
    @State private var showScanner = false
    @State private var showManualPair = false
    @State private var scannedPairing: PairingURL?

    var body: some View {
        NavigationStack {
            contentView
                .navigationTitle("Servers")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { showSettings = true } label: { Image(systemName: "gear") }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showAddSheet = true } label: { Image(systemName: "plus") }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { showScanner = true } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
                            Button { showManualPair = true } label: { Label("Enter Code Manually", systemImage: "keyboard") }
                        } label: {
                            Image(systemName: "link.badge.plus")
                        }
                    }
                    if hub.aggregate.enabledServers > 0 {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
                .sheet(isPresented: $showSettings) { SettingsView(settings: AppSettings.shared) }
                .sheet(isPresented: $showAddSheet) {
                    AddEditServerView(mode: .add) { _ in
                        viewModel.refreshServers()
                        hub.reloadBookmarks()
                    }
                }
                .sheet(item: $serverToEdit) { server in
                    AddEditServerView(mode: .edit(server), onSave: { saved in
                        viewModel.refreshServers()
                        hub.reloadBookmarks()
                        // The hub cannot see the keychain: a pasted token only
                        // reaches the relay through a fresh coordinator.
                        hub.rebuildSlot(saved.id)
                    }, onDelete: {
                        Task { await hub.removeServer(server.id); viewModel.refreshServers() }
                    })
                }
                .sheet(isPresented: $showScanner) {
                    NavigationStack {
                        QRScannerView { value in
                            showScanner = false
                            if let pairing = PairingURL(string: value) { scannedPairing = pairing }
                        }
                        .navigationTitle("Scan QR Code")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScanner = false } }
                        }
                    }
                }
                .sheet(item: $scannedPairing) { pairing in
                    PairWithHostSheet(onPaired: { _ in paired() }, prefill: pairing)
                }
                .sheet(isPresented: $showManualPair) {
                    PairWithHostSheet(onPaired: { _ in paired() }, prefill: nil)
                }
                .onAppear { viewModel.refreshServers() }
                .onDisappear { viewModel.stopPolling() }
        }
        .interactiveDismissDisabled(hub.aggregate.enabledServers == 0)
    }

    private func paired() {
        viewModel.refreshServers()
        hub.reloadBookmarks()          // paired bookmarks are saved enabled; the cap is enforced there
    }

    @ViewBuilder
    private var contentView: some View {
        if hub.sections.isEmpty {
            ContentUnavailableView {
                Label("No Servers", systemImage: "server.rack")
            } description: {
                Text("Add or pair a server to get started.")
            } actions: {
                Button("Add Server") { showAddSheet = true }
                Button("Pair with QR Code") { showScanner = true }
            }
        } else {
            List {
                if let notice = hub.notice {
                    Section { Text(notice).font(.footnote).foregroundStyle(.orange) }
                }
                ForEach(hub.sections) { section in
                    ServerRowView(
                        section: section,
                        probe: viewModel.serverStatuses[section.id],
                        onToggle: { on in
                            _ = hub.setEnabled(section.id, on)   // a refusal (cap of 8) leaves hub.notice
                            viewModel.refreshServers()
                        }
                    )
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await hub.removeServer(section.id); viewModel.refreshServers() }
                        } label: { Label("Delete", systemImage: "trash") }
                        Button { serverToEdit = section.config } label: { Label("Edit", systemImage: "pencil") }
                            .tint(.blue)
                    }
                }
                Section {
                    Text("\(hub.aggregate.enabledServers) of \(hub.aggregate.totalServers) enabled · up to 8 at once")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Server Row

struct ServerRowView: View {
    let section: ServerSection
    let probe: ServerStatus?
    let onToggle: (Bool) -> Void

    private var model: ServerSectionHeaderModel { ServerSectionHeaderModel(section: section) }

    /// Enabled bookmarks show the live coordinator's status; disabled ones the
    /// poller's probe (reachable / token rejected / offline).
    private var dotColor: Color {
        if section.config.enabled { return model.dotColor }
        guard let probe else { return .gray }
        if probe.reachability == .invalidToken { return .orange }
        return probe.isLive ? .green : .red
    }

    private var statusLabel: String {
        if section.config.enabled { return model.subtitle ?? "connected" }
        guard let probe else { return "disabled" }
        if probe.reachability == .invalidToken { return "disabled · token rejected" }
        return probe.isLive ? "disabled · reachable" : "disabled · offline"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(section.title).font(.body).fontWeight(.medium)
                    if section.isDuplicateInstance {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            .accessibilityLabel("Another bookmark points at this same relay")
                    }
                }
                Text(verbatim: "\(section.config.useTLS ? "wss" : "ws")://\(section.config.host):\(section.config.port)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                    Text(statusLabel).font(.caption2).foregroundStyle(.secondary)
                }
                if let instance = section.config.instanceId {
                    Text("instance \(instance.uuidString.prefix(8))…").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { section.config.enabled }, set: onToggle))
                .labelsHidden()
        }
    }
}
