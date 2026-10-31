import Foundation
import CodeRelayClient
import CodeRelayKit

/// iOS-specific `SessionCoordinator`: one per enabled bookmark, built by
/// `IOSServerHubFactory`. It connects and runs the launch handshake in
/// `start()`; everything workspace-level (scenePhase, keyboard, network
/// restored) lives in `WorkspaceView` and is fanned out by the hub (D10), so
/// this class installs no observers of its own.
@MainActor
final class SessionCoordinator: SharedSessionCoordinator {

    private let config: ConnectionConfig

    // SwiftLint wants `static` on a final class, but the parent's declaration is
    // `open class var`, so the override MUST use `class`.
    // swiftlint:disable:next static_over_final_class
    override class var keyPrefix: String { "com.clauderelay" }

    override func sessionNamingTheme() -> SessionNamingTheme {
        AppSettings.shared.sessionNamingTheme
    }

    /// - Parameter ownershipKeyPrefix: per-server UserDefaults namespace from
    ///   the hub (multi-server D8); nil keeps the single-server default.
    init(config: ConnectionConfig, token: String, ownershipKeyPrefix: String? = nil) {
        self.config = config
        super.init(connection: RelayConnection(), token: token, ownershipKeyPrefix: ownershipKeyPrefix)
    }

    /// Dial, then the single-flight launch handshake (authenticate + list the
    /// sessions this client owns). A failed first dial falls through: the
    /// handshake reconnects on its own, so it becomes a retry rather than a
    /// dead section. Mirrors the macOS subclass exactly.
    override func start(reason: SessionHandshake.Reason) async {
        do {
            try await connection.connect(config: config, token: token)
        } catch {
            presentError(error.localizedDescription)
        }
        await performHandshake(reason: reason)
    }
}
