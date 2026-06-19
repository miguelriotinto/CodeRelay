import SwiftUI
import AppKit
import ClaudeRelayClient

@main
struct ClaudeRelayMacApp: App {

    /// Platform-scoped server bookmark storage. No legacy key; Mac app
    /// shipped with the current key from day one.
    static let savedConnections = SavedConnectionStore(
        key: "com.clauderelay.mac.savedConnections"
    )

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Code Relay") {
            MainWindow()
                .frame(minWidth: 800, minHeight: 500)
                .onOpenURL { url in
                    handleDeepLink(url)
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
