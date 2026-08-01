import SwiftUI
import AppKit
import ClaudeRelayClient
import ClaudeRelayKit

@main
struct ClaudeRelayMacApp: App {

    /// Platform-scoped server bookmark storage. No legacy key; Mac app
    /// shipped with the current key from day one.
    static let savedConnections = SavedConnectionStore(
        key: "com.clauderelay.mac.savedConnections"
    )

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var pendingPairing: PairingURL?
    @State private var pendingConnectConfig: ConnectionConfig?

    var body: some Scene {
        WindowGroup("Code[Relay]") {
            MainWindow()
                .frame(minWidth: 800, minHeight: 500)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .onReceive(PushTokenBridge.shared.$pendingDeepLink.compactMap { $0 }) { url in
                    handleDeepLink(url)
                    PushTokenBridge.shared.pendingDeepLink = nil
                }
                .sheet(item: $pendingPairing) { pairing in
                    PairWithHostSheet(
                        onPaired: { config in
                            pendingConnectConfig = config
                        },
                        prefill: pairing
                    )
                }
                .onChange(of: pendingConnectConfig) { _, config in
                    if let config {
                        NotificationCenter.default.post(
                            name: .connectToServer,
                            object: config
                        )
                        pendingConnectConfig = nil
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            AppCommands()
        }

        MenuBarExtra {
            MenuBarDropdown()
        } label: {
            Image(systemName: "terminal")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }

    private func handleDeepLink(_ url: URL) {
        // Handle pairing deep links first (before any coordinator exists)
        if url.host == "pair", let pairing = PairingURL(url: url) {
            pendingPairing = pairing
            return
        }

        // Handle session deep links
        guard url.scheme == "clauderelay",
              url.host == "session",
              let uuidString = url.pathComponents.dropFirst().first,
              let uuid = UUID(uuidString: uuidString) else {
            return
        }
        Task { @MainActor in
            if let coordinator = ActiveCoordinatorRegistry.shared.coordinator {
                await coordinator.attachRemoteSession(id: uuid)
            }
        }
    }
}
