import Foundation

/// Configuration for connecting to a ClaudeRelay server.
public struct ConnectionConfig: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var useTLS: Bool

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
        useTLS: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
    }
}
