import Foundation

/// Addresses a session across servers (multi-server spec §5.1): the local
/// bookmark id plus the server-scoped session id. Session UUIDs are minted
/// per relay and die with it, so a bare `UUID` is only meaningful inside one
/// coordinator; everything that spans servers — the hub's active selection,
/// last-session restore, deep-link routing, sidebar selection — uses this.
public struct SessionRef: Hashable, Codable, Sendable {
    public let serverId: UUID
    public let sessionId: UUID

    public init(serverId: UUID, sessionId: UUID) {
        self.serverId = serverId
        self.sessionId = sessionId
    }
}
