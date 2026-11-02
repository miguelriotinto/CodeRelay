import SwiftUI
import AVFoundation
import CodeRelayClient
import CodeRelayKit

/// Offers every live server's attachable sessions, grouped under each server's
/// name when there is more than one, and attaches through the hub on the row's
/// own server. It used to ask the focus server alone, so a second server's
/// sessions could never be offered.
struct AttachRemoteSessionSheet: View {
    @ObservedObject var hub: MacServerHub
    @Environment(\.dismiss) private var dismiss

    @State private var groups: [AttachableGroup] = []
    @State private var isLoading = true
    @State private var selection: SessionRef?
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
            } else if groups.allSatisfy({ $0.sessions.isEmpty }) {
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
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.sessions, id: \.id) { session in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.name ?? String(session.id.uuidString.prefix(8)))
                                        .font(.headline)
                                    Text("State: \(session.state.rawValue) · Created \(session.createdAt.formatted(.dateTime))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                                .tag(SessionRef(serverId: group.serverId, sessionId: session.id))
                            }
                        } header: {
                            if groups.count > 1 {
                                Text(group.sessions.isEmpty ? "\(group.title) — no sessions" : group.title)
                            }
                        }
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
                    guard let ref = selection else { return }
                    let serverName = groups.first { $0.serverId == ref.serverId }?
                        .sessions.first { $0.id == ref.sessionId }?.name
                    Task {
                        await hub.attachRemote(on: ref.serverId, sessionId: ref.sessionId, serverName: serverName)
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
            groups = await hub.attachableSessions()
            isLoading = false
        }
        .sheet(isPresented: $showQRScanner) {
            if let focus = hub.focusCoordinator {
                QRScannerSheet(coordinator: focus, onAttachSuccess: { dismiss() })
            }
        }
    }
}
