import Foundation

/// Configuration for connecting to a CodeRelay server — one saved bookmark.
public struct ConnectionConfig: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var useTLS: Bool
    /// Multi-server (spec §9): whether the hub keeps a live coordinator for
    /// this bookmark. Pre-feature bookmarks decode as enabled; the one-time
    /// migration then turns off every bookmark except the last-used one.
    public var enabled: Bool
    /// The relay's persisted instance id, learned from the first v3
    /// `auth_success` (spec §5.2). Routing hint only — never the session key.
    public var instanceId: UUID?
    /// The relay's own `serverName`, learned alongside `instanceId`.
    public var displayName: String?

    /// Constructs the WebSocket URL from the configuration properties.
    /// Returns `nil` if the stored host contains characters that RFC 3986
    /// forbids in a URL (a corrupted bookmark, for instance).
    public var wsURL: URL? {
        let scheme = useTLS ? "wss" : "ws"
        return URL(string: "\(scheme)://\(host):\(port)")
    }

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16 = 9200,
        useTLS: Bool = false,
        enabled: Bool = true,
        instanceId: UUID? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.enabled = enabled
        self.instanceId = instanceId
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, useTLS, enabled, instanceId, displayName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(UInt16.self, forKey: .port)
        useTLS = try c.decode(Bool.self, forKey: .useTLS)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        instanceId = try c.decodeIfPresent(UUID.self, forKey: .instanceId)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
    }
}
