import Foundation
import CodeRelayKit

/// A session the user had in the pane that is no longer there.
public struct LostSession: Equatable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum SessionLossKind: Sendable { case taken, ended }

/// Pure classification of sessions that disappeared from this token's list.
public enum SessionLossClassifier {
    /// Entries of `before` not present as non-terminal in `owned`, order preserved.
    public static func lost(before: [LostSession], owned: [SessionInfo]) -> [LostSession] {
        let live = Set(owned.filter { !$0.state.isTerminal }.map(\.id))
        return before.filter { !live.contains($0.id) }
    }

    /// Splits lost sessions using the unscoped list. A session is `taken` when it
    /// is still alive under another token; otherwise it `ended`. A nil `all`
    /// (list unavailable) is treated as taken for every session.
    public static func classify(
        lost: [LostSession], all: [SessionInfo]?, myTokenId: String
    ) -> (taken: [LostSession], ended: [LostSession]) {
        guard let all else { return (lost, []) }
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var taken: [LostSession] = []
        var ended: [LostSession] = []
        for session in lost {
            if let info = byId[session.id], !info.state.isTerminal, info.tokenId != myTokenId {
                taken.append(session)
            } else {
                ended.append(session)
            }
        }
        return (taken, ended)
    }
}

public struct SessionLossItem: Equatable, Sendable {
    public let serverId: UUID
    public let serverName: String
    public let session: LostSession

    public init(serverId: UUID, serverName: String, session: LostSession) {
        self.serverId = serverId
        self.serverName = serverName
        self.session = session
    }
}

public enum SessionLossCopy {
    public static func takenTitle(count: Int) -> String {
        count == 1 ? "Session Moved" : "Sessions Moved"
    }

    public static func takenBody(_ items: [SessionLossItem]) -> String {
        body(items, one: "was attached from another device.",
             many: "were attached from another device.")
    }

    public static func endedBody(_ items: [SessionLossItem]) -> String {
        body(items, one: "ended while you were away.", many: "ended while you were away.")
    }

    private static func body(_ items: [SessionLossItem], one: String, many: String) -> String {
        let multiServer = Set(items.map(\.serverId)).count > 1
        let names = items.map { multiServer ? "\($0.session.name) (on \($0.serverName))" : $0.session.name }
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) \(one)"
        case 2: return "\(names[0]) and \(names[1]) \(many)"
        default:
            let rest = names.count - 2
            return "\(names[0]), \(names[1]) and \(rest) \(rest == 1 ? "other" : "others") \(many)"
        }
    }
}
