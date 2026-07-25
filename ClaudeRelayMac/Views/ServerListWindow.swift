import SwiftUI
import ClaudeRelayClient

struct ServerListWindow: View {
    @StateObject private var viewModel = ServerListViewModel()
    @State private var addEditTarget: AddEditTarget?
    @State private var showDeleteAlert = false
    @State private var deleteTarget: ConnectionConfig?

    /// Callback when the user connects to a server.
    var onConnect: ((ConnectionConfig) -> Void)?

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
                ForEach(viewModel.connections, id: \.id) { connection in
                    ServerRow(
                        connection: connection,
                        isReachable: viewModel.statuses[connection.id]?.isLive ?? false,
                        isTokenInvalid: viewModel.statuses[connection.id]?.reachability == .invalidToken
                    )
                    .contextMenu {
                        Button("Connect") { connectTo(connection) }
                        Button("Edit...") { addEditTarget = .edit(connection) }
                        Divider()
                        Button("Delete", role: .destructive) {
                            deleteTarget = connection
                            showDeleteAlert = true
                        }
                    }
                    .tag(connection.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Button {
                    addEditTarget = .add
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                Spacer()
                Button("Connect") {
                    if let c = viewModel.selectedConnection() {
                        connectTo(c)
                    }
                }
                .disabled(viewModel.selectedConnection() == nil)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(12)
        }
        .background(.black)
        .frame(minWidth: 500, minHeight: 360)
        // Stop the 5s status poll as soon as the sheet closes. The @StateObject
        // is released when the sheet dismisses, and `ServerStatusChecker.deinit`
        // now cancels the loop — but calling it here stops the churn on the same
        // runloop turn instead of waiting for ARC to release the view model.
        .onDisappear { viewModel.stopAllPolling() }
        .navigationTitle("Servers")
        .toolbarBackground(.black, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .sheet(item: $addEditTarget) { target in
            AddEditServerView(target: target) { newConnection in
                viewModel.addOrUpdate(newConnection)
                addEditTarget = nil
            }
        }
        .alert("Delete Server?", isPresented: $showDeleteAlert, presenting: deleteTarget) { target in
            Button("Delete", role: .destructive) {
                viewModel.delete(id: target.id)
                try? AuthManager.shared.deleteToken(for: target.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("Are you sure you want to delete '\(target.name)'?")
        }
    }

    private func connectTo(_ connection: ConnectionConfig) {
        viewModel.markAsLastUsed(connection.id)
        onConnect?(connection)
    }
}

private struct ServerRow: View {
    let connection: ConnectionConfig
    let isReachable: Bool
    var isTokenInvalid: Bool = false

    private var dotColor: Color {
        if isTokenInvalid { return .orange }
        return isReachable ? .green : .red
    }

    var body: some View {
        HStack {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name).font(.headline)
                Text("\(connection.useTLS ? "wss" : "ws")://\(connection.host):\(connection.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isTokenInvalid {
                    Text("Invalid token")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
