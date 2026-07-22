import Foundation
import Combine

/// Cross-platform bridge between the OS push callbacks (app delegate) and the
/// session coordinator / SwiftUI layer. The delegate publishes the device
/// token and any tapped deep-link here; observers react.
///
/// `@MainActor` + `ObservableObject` so SwiftUI views and the coordinator can
/// observe it directly.
@MainActor
public final class PushTokenBridge: ObservableObject {
    public static let shared = PushTokenBridge()

    /// The APNs/FCM device token as a hex string, once the OS vends one.
    @Published public var deviceToken: String?
    /// A deep-link URL from a tapped notification, pending navigation.
    @Published public var pendingDeepLink: URL?
    /// Whether the user granted notification permission (nil = undetermined).
    @Published public var permissionGranted: Bool?

    public init() {}

    /// Convert raw APNs token `Data` to the lowercase hex string the wire
    /// protocol expects.
    public func setAPNsToken(_ data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
    }
}
