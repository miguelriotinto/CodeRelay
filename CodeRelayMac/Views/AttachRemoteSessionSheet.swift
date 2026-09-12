import SwiftUI
import AVFoundation
import CodeRelayKit

struct AttachRemoteSessionSheet: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [SessionInfo] = []
    @State private var isLoading = true
    @State private var selection: UUID?
    @State private var showQRScanner = false
    @State private var hasCamera = AVCaptureDevice.default(for: .video) != nil

    var body: some View {
        VStack(spacing: 0) {
            Text("Attach Session")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if isLoading {
                ProgressView("Looking for sessions...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No remote sessions available")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(sessions, id: \.id) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name ?? String(session.id.uuidString.prefix(8)))
                                .font(.headline)
                            Text("State: \(session.state.rawValue) · Created \(session.createdAt.formatted(.dateTime))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(session.id)
                    }
                }
                .listStyle(.inset)
                .padding(.horizontal, 8)
            }

            Divider()
            HStack {
                if hasCamera {
                    Button {
                        showQRScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Attach") {
                    guard let id = selection else { return }
                    let serverName = sessions.first { $0.id == id }?.name
                    Task {
                        await coordinator.attachRemoteSession(id: id, serverName: serverName)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(12)
        }
        .frame(width: 480, height: 400)
        .task {
            sessions = await coordinator.fetchAttachableSessions()
            isLoading = false
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerSheet(coordinator: coordinator, onAttachSuccess: { dismiss() })
        }
    }
}
