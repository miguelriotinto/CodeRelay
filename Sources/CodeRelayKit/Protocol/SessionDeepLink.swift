import Foundation

/// `coderelay://session/<sessionId>?server=<instanceId>` — the link a push
/// notification, a QR code or another app hands a client to open a session
/// (multi-server spec §10). `server` is the relay's persisted instance id
/// (`ServerIdentity.id`); it is optional because v2 relays and hand-typed
/// links omit it, and a malformed value is ignored rather than failing the
/// whole link. The pre-rename `clauderelay` scheme is still accepted so QR
/// codes printed by old builds keep scanning.
public struct SessionDeepLink: Equatable, Sendable {
    public static let scheme = "coderelay"
    public static let legacyScheme = "clauderelay"
    public static let host = "session"
    public static let serverQueryItem = "server"

    public let sessionId: UUID
    public let serverInstanceId: UUID?

    public init(sessionId: UUID, serverInstanceId: UUID? = nil) {
        self.sessionId = sessionId
        self.serverInstanceId = serverInstanceId
    }

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == Self.scheme || scheme == Self.legacyScheme,
              url.host?.lowercased() == Self.host,
              let first = url.pathComponents.dropFirst().first,
              let sessionId = UUID(uuidString: first) else {
            return nil
        }
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == Self.serverQueryItem })?.value
        self.sessionId = sessionId
        self.serverInstanceId = raw.flatMap(UUID.init(uuidString:))
    }

    public init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url: url)
    }

    public var urlString: String {
        var s = "\(Self.scheme)://\(Self.host)/\(sessionId.uuidString)"
        if let serverInstanceId {
            s += "?\(Self.serverQueryItem)=\(serverInstanceId.uuidString)"
        }
        return s
    }

    /// Always valid: every component is a fixed token or a UUID string.
    public var url: URL { URL(string: urlString)! }
}
