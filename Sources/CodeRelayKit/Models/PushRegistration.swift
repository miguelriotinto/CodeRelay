import Foundation

/// Push delivery platform for a registered device.
public enum PushPlatform: String, Codable, Sendable {
    case apns
    case fcm
}

/// A device's push registration: the platform token plus per-device delivery
/// preferences and a timestamp for TTL reaping. Sent by the client over
/// `registerPushToken` and persisted server-side per relay token.
public struct PushRegistration: Codable, Equatable, Sendable {
    public let platform: PushPlatform
    public let token: String
    public let deviceId: String
    public var enabled: Bool
    public var notifyOnFinished: Bool
    public var updatedAt: Date
    /// APNs delivery topic (the app's bundle id) for this device. iOS and macOS
    /// share the `.apns` platform but require different `apns-topic` headers, so
    /// the device reports its own bundle id here. `nil` for FCM and for older
    /// clients — the server then falls back to the configured `apnsBundleId`.
    public var topic: String?
    /// The APNs environment this device's token belongs to: `true` = sandbox
    /// (a development-signed build), `false` = production (TestFlight, App
    /// Store, Developer ID). Read by the app from its own provisioning profile.
    /// A token sent to the wrong endpoint is answered `BadDeviceToken`, which
    /// the relay reads as a dead token and purges — so one relay-wide switch
    /// could serve only one kind of build. `nil` (FCM, older clients) falls back
    /// to the configured `apnsUseSandbox`.
    public var sandbox: Bool?

    public init(platform: PushPlatform, token: String, deviceId: String,
                enabled: Bool, notifyOnFinished: Bool, updatedAt: Date, topic: String? = nil,
                sandbox: Bool? = nil) {
        self.platform = platform
        self.token = token
        self.deviceId = deviceId
        self.enabled = enabled
        self.notifyOnFinished = notifyOnFinished
        self.updatedAt = updatedAt
        self.topic = topic
        self.sandbox = sandbox
    }

    /// Bounds untrusted input before it enters persisted maps: non-empty token
    /// ≤ 512 chars, non-empty deviceId ≤ 128 chars, optional topic ≤ 256 chars.
    public var isValid: Bool {
        !token.isEmpty && token.count <= 512 && !deviceId.isEmpty && deviceId.count <= 128
            && (topic.map { !$0.isEmpty && $0.count <= 256 } ?? true)
    }
}
