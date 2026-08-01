import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

struct ServerListView: View {
    @StateObject private var viewModel = ServerListViewModel()
    @Binding var pendingSessionId: UUID?
    @Binding var pendingConnectConfig: ConnectionConfig?
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
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        }
                        Button {
                            showManualPair = true
                        } label: {
                            Label("Enter Code Manually", systemImage: "keyboard")
                        }
                    } label: {
                        Image(systemName: "link.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: AppSettings.shared)
            }
            .sheet(isPresented: $showAddSheet) {
                AddEditServerView(mode: .add) { _ in
                    viewModel.refreshServers()
                }
            }
            .sheet(item: $serverToEdit) { server in
                AddEditServerView(mode: .edit(server), onSave: { _ in
                    viewModel.refreshServers()
                }, onDelete: {
                    viewModel.deleteServer(id: server.id)
                })
            }
            .sheet(isPresented: $viewModel.isConnecting) {
                ConnectingView(
                    serverName: viewModel.connectingServerName ?? "Server",
                    onCancel: { viewModel.cancelConnect() }
                )
                .interactiveDismissDisabled()
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }
            .fullScreenCover(isPresented: $viewModel.isNavigatingToWorkspace) {
                viewModel.resetNavigationState()
            } content: {
                if let connection = viewModel.activeConnection,
                   let token = viewModel.activeToken {
                    WorkspaceView(
                        connection: connection,
                        token: token,
                        pendingAttachSessionId: consumePendingSession()
                    )
                }
            }
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    QRScannerView { value in
                        showScanner = false
                        if let pairing = PairingURL(string: value) {
                            scannedPairing = pairing
                        }
                    }
                    .navigationTitle("Scan QR Code")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showScanner = false }
                        }
                    }
                }
            }
            .sheet(item: $scannedPairing) { pairing in
                PairWithHostSheet(onPaired: { config in
                    viewModel.refreshServers()
                    viewModel.startConnect(to: config)
                }, prefill: pairing)
            }
            .sheet(isPresented: $showManualPair) {
                PairWithHostSheet(onPaired: { config in
                    viewModel.refreshServers()
                    viewModel.startConnect(to: config)
                }, prefill: nil)
            }
            .onAppear {
                viewModel.refreshServers()
                viewModel.startPolling()
            }
            .onChange(of: pendingSessionId) { _, sessionId in
                guard sessionId != nil, !viewModel.isNavigatingToWorkspace else { return }
                if let first = viewModel.servers.first {
                    viewModel.startConnect(to: first)
                }
            }
            .onChange(of: pendingConnectConfig) { _, config in
                guard let config = config else { return }
                viewModel.refreshServers()
                viewModel.startConnect(to: config)
                pendingConnectConfig = nil
            }
        }
    }

    private func consumePendingSession() -> UUID? {
        defer { pendingSessionId = nil }
        return pendingSessionId
    }

    @ViewBuilder
    private var contentView: some View {
        Group {
            if viewModel.servers.isEmpty {
                ContentUnavailableView {
                    Label("No Servers", systemImage: "server.rack")
                } description: {
                    Text("Add a server to get started.")
                } actions: {
                    Button("Add Server") {
                        showAddSheet = true
                    }
                }
            } else {
                List {
                    ForEach(viewModel.servers) { server in
                        Button {
                            viewModel.startConnect(to: server)
                        } label: {
                            ServerRowView(
                                server: server,
                                status: viewModel.serverStatuses[server.id],
                                isConnected: viewModel.connectedServerId == server.id
                            )
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                viewModel.deleteServer(id: server.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                serverToEdit = server
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .refreshable {
                    viewModel.refreshStatuses()
                }
            }
        }
    }
}

// MARK: - Connecting Modal

struct ConnectingView: View {
    let serverName: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text("Connecting to \(serverName)...")
                .font(.headline)

            Text("Establishing secure connection")
                .font(.subheadline)
                .foregroundStyle(.secondary)

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

// MARK: - Server Row

struct ServerRowView: View {
    let server: ConnectionConfig
    let status: ServerStatus?
    var isConnected: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.body)
                    .fontWeight(.medium)
                Text(verbatim: "\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor(status))
                        .frame(width: 8, height: 8)
                    Text(statusLabel(status))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private func statusColor(_ status: ServerStatus?) -> Color {
        switch status?.reachability {
        case .live:         return .green
        case .invalidToken: return .orange
        default:            return .red
        }
    }

    private func statusLabel(_ status: ServerStatus?) -> String {
        switch status?.reachability {
        case .live:         return "Live"
        case .invalidToken: return "Invalid token"
        default:            return "Offline"
        }
    }
}

#Preview {
    ServerListView(
        pendingSessionId: .constant(nil),
        pendingConnectConfig: .constant(nil)
    )
}
