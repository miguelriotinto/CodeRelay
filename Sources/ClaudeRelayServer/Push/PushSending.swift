import Foundation
import ClaudeRelayKit

/// Outcome of a single push delivery attempt.
public enum PushResult: Equatable, Sendable {
    /// Accepted by the provider for delivery.
    case delivered
    /// The device token is dead (APNs 410 / FCM UNREGISTERED) — purge it.
    case unregistered
    /// Any other failure; the string is a redacted, human-readable reason.
    case failed(String)
}

/// Sends a single push to one device token. Implemented by `APNsClient`,
/// `FCMClient`, and `CompositePushSender` (which routes by platform).
///
/// `topic` is the device's APNs delivery topic (its bundle id); it lets one
/// APNs provider fan out to distinct iOS/macOS apps. `nil` means "use the
/// configured default"; FCM ignores it.
public protocol PushSending: Sendable {
    func send(deviceToken: String, platform: PushPlatform, topic: String?, title: String,
              body: String, deepLink: String, collapseKey: String) async -> PushResult
}

/// Routes each send to the provider matching the device's platform. Missing a
/// provider for a platform yields `.failed` (never crashes).
public struct CompositePushSender: PushSending {
    private let apns: PushSending?
    private let fcm: PushSending?

    public init(apns: PushSending?, fcm: PushSending?) {
        self.apns = apns
        self.fcm = fcm
    }

    public func send(deviceToken: String, platform: PushPlatform, topic: String?, title: String,
                     body: String, deepLink: String, collapseKey: String) async -> PushResult {
        let sender: PushSending?
        switch platform {
        case .apns: sender = apns
        case .fcm:  sender = fcm
        }
        guard let sender else { return .failed("no sender configured for \(platform.rawValue)") }
        return await sender.send(deviceToken: deviceToken, platform: platform, topic: topic,
                                 title: title, body: body, deepLink: deepLink, collapseKey: collapseKey)
    }
}
