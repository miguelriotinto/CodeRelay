import Foundation
import ClaudeRelayKit

/// Decides what push-registration action to take from the current inputs, so
/// the register/update/unregister logic is unit-testable independent of the
/// platform notification APIs. Shared by iOS and macOS (and mirrored on
/// Android as `PushRegistrationController.kt`).
public enum PushRegistrationController {
    public enum Action: Equatable {
        /// Send `registerPushToken` with these preferences (also used to update
        /// prefs — registration is idempotent by deviceId).
        case register(enabled: Bool, notifyOnFinished: Bool)
        /// Send `unregisterPushToken`.
        case unregister
        /// Do nothing (not connected / no token / permission not granted).
        case noop
    }

    /// - Parameters:
    ///   - permissionGranted: OS notification authorization granted.
    ///   - deviceToken: the APNs/FCM token, if the OS has vended one.
    ///   - connected: an authenticated relay connection exists.
    ///   - pushEnabledSetting: the app's "Push Notifications" toggle.
    ///   - notifyOnFinished: the app's "notify on finished" preference.
    public static func decide(permissionGranted: Bool,
                              deviceToken: String?,
                              connected: Bool,
                              pushEnabledSetting: Bool,
                              notifyOnFinished: Bool) -> Action {
        guard connected else { return .noop }
        // Toggle off (or permission revoked) → unregister so delivery stops.
        guard pushEnabledSetting, permissionGranted else { return .unregister }
        // Enabled but no token vended yet → nothing to send.
        guard deviceToken != nil else { return .noop }
        return .register(enabled: true, notifyOnFinished: notifyOnFinished)
    }
}
