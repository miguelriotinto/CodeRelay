import Foundation
import CodeRelayClient
import CodeRelayKit

/// iOS-specific `SessionCoordinator`. Deliberately thin — the iOS app's
/// workspace-level glue (scenePhase, keyboard, etc.) lives in SwiftUI views,
/// so this subclass only exists to provide a concrete type alongside the
/// macOS variant (`CodeRelayMac/ViewModels/SessionCoordinator.swift`),
/// which adds sleep/wake observers and tab navigation hooks.
@MainActor
final class SessionCoordinator: SharedSessionCoordinator {

    // SwiftLint wants `static` on a final class, but the parent's declaration is
    // `open class var`, so the override MUST use `class`.
    // swiftlint:disable:next static_over_final_class
    override class var keyPrefix: String { "com.clauderelay" }

    override func sessionNamingTheme() -> SessionNamingTheme {
        AppSettings.shared.sessionNamingTheme
    }
}
