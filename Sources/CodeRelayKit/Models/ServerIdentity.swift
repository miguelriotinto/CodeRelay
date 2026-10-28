import Foundation

/// A relay's self-identification (multi-server spec §5.2, §6).
///
/// `id` is minted once per server install and persisted by the server
/// (`~/.claude-relay/instance.json`), so it survives restarts, host renames and
/// port changes. `name` is the operator-facing label: the `serverName` config
/// key when set, else the host name. Clients use `id` only to route push deep
/// links and to detect two bookmarks pointing at one relay — never as the key
/// for sessions, which stay scoped to the local bookmark.
public struct ServerIdentity: Equatable, Hashable, Sendable, Codable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    /// Builds the identity from the two optional wire keys. Returns nil when
    /// `serverId` is absent or not a UUID — a malformed hint must never fail
    /// the message that carries it. A missing name decodes as `""`.
    static func fromWire(serverId: String?, serverName: String?) -> ServerIdentity? {
        guard let serverId, let id = UUID(uuidString: serverId) else { return nil }
        return ServerIdentity(id: id, name: serverName ?? "")
    }
}
