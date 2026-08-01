import Foundation

/// Configuration model for the ClaudeRelay server.
public struct RelayConfig: Codable, Sendable {

    /// Ports the server accepts for `wsPort`/`adminPort`. The 1024 floor is
    /// project policy: 1–1023 are privileged and need root to bind, and 0 would
    /// request an arbitrary ephemeral port, which is useless for a config a
    /// client has to dial back into.
    ///
    /// Single source of truth for every layer that checks a port —
    /// `AdminRoutes.validatePort` (server), `ConfigSetCommand` and
    /// `ConfigValidateCommand` (CLI). Previously each restated the bound:
    /// `ConfigSetCommand` and `AdminRoutes` both hard-coded `1024...65535`, while
    /// `ConfigValidateCommand` compared against `1` and `65535` and so reported
    /// privileged ports as valid.
    public static let portRange = 1024...65535

    /// WebSocket listening port.
    public var wsPort: UInt16

    /// Admin API listening port.
    public var adminPort: UInt16

    /// Seconds before a detached session is reaped. 0 = never expire (default).
    public var detachTimeout: Int

    /// Maximum scrollback buffer size in bytes.
    public var scrollbackSize: Int

    /// Optional path to a TLS certificate file.
    public var tlsCert: String?

    /// Optional path to a TLS private-key file.
    public var tlsKey: String?

    /// Logging verbosity (e.g. "trace", "debug", "info", "warning", "error").
    public var logLevel: String

    /// Maximum active (non-terminal) sessions per token. 0 means unlimited.
    public var maxSessionsPerToken: Int

    /// When true (default), the WebSocket server binds `0.0.0.0` — reachable
    /// from every network interface on the host (loopback + LAN + any VPN or
    /// bridge addresses). Set to `false` to bind `127.0.0.1` only, which
    /// restricts the server to the local machine.
    ///
    /// Security note: without TLS configured, tokens are transmitted in the
    /// clear on whatever network the server is bound to. The startup log
    /// warns explicitly when `bindAll` is true without TLS.
    public var bindAll: Bool

    // MARK: - Push notifications (all off / nil by default)

    /// Master switch — when false, push tokens are still accepted and stored
    /// (so enabling later needs no client reconnect) but nothing is delivered.
    public var pushEnabled: Bool
    /// Server-wide default for whether to notify on agent-finished (a device's
    /// own preference overrides this).
    public var pushNotifyOnFinished: Bool
    /// APNs token-based auth: path to the `.p8` key, its key id, team id, and
    /// the app bundle id (`apns-topic`).
    public var apnsKeyPath: String?
    public var apnsKeyId: String?
    public var apnsTeamId: String?
    public var apnsBundleId: String?
    /// Use the APNs sandbox host (development builds).
    public var apnsUseSandbox: Bool
    /// FCM HTTP v1: path to the service-account JSON and the Firebase project id.
    public var fcmServiceAccountPath: String?
    public var fcmProjectId: String?

    // MARK: - Initializer

    public init(
        wsPort: UInt16 = 9200,
        adminPort: UInt16 = 9100,
        detachTimeout: Int = 0,
        scrollbackSize: Int = 524288,
        tlsCert: String? = nil,
        tlsKey: String? = nil,
        logLevel: String = "info",
        maxSessionsPerToken: Int = 50,
        bindAll: Bool = true,
        pushEnabled: Bool = false,
        pushNotifyOnFinished: Bool = false,
        apnsKeyPath: String? = nil,
        apnsKeyId: String? = nil,
        apnsTeamId: String? = nil,
        apnsBundleId: String? = nil,
        apnsUseSandbox: Bool = false,
        fcmServiceAccountPath: String? = nil,
        fcmProjectId: String? = nil
    ) {
        self.wsPort = wsPort
        self.adminPort = adminPort
        self.detachTimeout = detachTimeout
        self.scrollbackSize = scrollbackSize
        self.tlsCert = tlsCert
        self.tlsKey = tlsKey
        self.logLevel = logLevel
        self.maxSessionsPerToken = maxSessionsPerToken
        self.bindAll = bindAll
        self.pushEnabled = pushEnabled
        self.pushNotifyOnFinished = pushNotifyOnFinished
        self.apnsKeyPath = apnsKeyPath
        self.apnsKeyId = apnsKeyId
        self.apnsTeamId = apnsTeamId
        self.apnsBundleId = apnsBundleId
        self.apnsUseSandbox = apnsUseSandbox
        self.fcmServiceAccountPath = fcmServiceAccountPath
        self.fcmProjectId = fcmProjectId
    }

    // MARK: - Computed Properties

    /// True when TLS is enabled (both cert and key paths are present and non-empty).
    public var tlsEnabled: Bool {
        guard let certPath = tlsCert, !certPath.isEmpty else { return false }
        guard let keyPath = tlsKey, !keyPath.isEmpty else { return false }
        return true
    }

    // MARK: - Static Properties

    /// An instance populated with all default values.
    public static let `default` = RelayConfig()

    /// The configuration directory: `~/.claude-relay/`.
    public static let configDirectory: URL = {
        #if os(iOS) || os(tvOS) || os(watchOS)
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(".claude-relay", isDirectory: true)
        #else
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-relay", isDirectory: true)
        #endif
    }()

    /// The main configuration file: `~/.claude-relay/config.json`.
    public static let configFile: URL = configDirectory.appendingPathComponent("config.json")

    /// The tokens file: `~/.claude-relay/tokens.json`.
    public static let tokensFile: URL = configDirectory.appendingPathComponent("tokens.json")

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case wsPort, adminPort, detachTimeout, scrollbackSize
        case tlsCert, tlsKey, logLevel, maxSessionsPerToken, bindAll
        case pushEnabled, pushNotifyOnFinished
        case apnsKeyPath, apnsKeyId, apnsTeamId, apnsBundleId, apnsUseSandbox
        case fcmServiceAccountPath, fcmProjectId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.wsPort = try c.decodeIfPresent(UInt16.self, forKey: .wsPort) ?? 9200
        self.adminPort = try c.decodeIfPresent(UInt16.self, forKey: .adminPort) ?? 9100
        self.detachTimeout = try c.decodeIfPresent(Int.self, forKey: .detachTimeout) ?? 0
        self.scrollbackSize = try c.decodeIfPresent(Int.self, forKey: .scrollbackSize) ?? 524288
        self.tlsCert = try c.decodeIfPresent(String.self, forKey: .tlsCert)
        self.tlsKey = try c.decodeIfPresent(String.self, forKey: .tlsKey)
        self.logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? "info"
        self.maxSessionsPerToken = try c.decodeIfPresent(Int.self, forKey: .maxSessionsPerToken) ?? 50
        // Default is true — the server accepts connections from any interface
        // (0.0.0.0). Existing configs that never mentioned bindAll inherit
        // this default and keep their previous behavior. Set `bindAll=false`
        // explicitly to bind loopback only.
        self.bindAll = try c.decodeIfPresent(Bool.self, forKey: .bindAll) ?? true
        self.pushEnabled = try c.decodeIfPresent(Bool.self, forKey: .pushEnabled) ?? false
        self.pushNotifyOnFinished = try c.decodeIfPresent(Bool.self, forKey: .pushNotifyOnFinished) ?? false
        self.apnsKeyPath = try c.decodeIfPresent(String.self, forKey: .apnsKeyPath)
        self.apnsKeyId = try c.decodeIfPresent(String.self, forKey: .apnsKeyId)
        self.apnsTeamId = try c.decodeIfPresent(String.self, forKey: .apnsTeamId)
        self.apnsBundleId = try c.decodeIfPresent(String.self, forKey: .apnsBundleId)
        self.apnsUseSandbox = try c.decodeIfPresent(Bool.self, forKey: .apnsUseSandbox) ?? false
        self.fcmServiceAccountPath = try c.decodeIfPresent(String.self, forKey: .fcmServiceAccountPath)
        self.fcmProjectId = try c.decodeIfPresent(String.self, forKey: .fcmProjectId)
    }
}
