import Foundation

/// Messages sent from the server to the client.
public enum ServerMessage: Equatable, Sendable {
    case authSuccess(protocolVersion: Int? = nil, tokenId: String? = nil)
    case authFailure(reason: String)
    case sessionCreated(sessionId: UUID, cols: UInt16, rows: UInt16)
    case sessionAttached(sessionId: UUID, state: String)
    case sessionResumed(sessionId: UUID)
    case replayComplete(sessionId: UUID)
    case sessionDetached
    case sessionTerminated(sessionId: UUID, reason: String)
    case sessionExpired(sessionId: UUID)
    case sessionState(sessionId: UUID, state: String)
    case sessionActivity(
        sessionId: UUID, activity: ActivityState, agent: String? = nil,
        agentState: AgentDetectedState? = nil, title: String? = nil, workingDir: String? = nil
    )
    case sessionStolen(sessionId: UUID)
    case sessionRenamed(sessionId: UUID, name: String)
    case sessionList(sessions: [SessionInfo])
    case sessionListAll(sessions: [SessionInfo])
    case resizeAck(cols: UInt16, rows: UInt16)
    case pasteImageResult(success: Bool)
    case pong
    case pushTokenAck(accepted: Bool)
    /// F11: the terminal wrote to the clipboard via OSC 52 — the client mirrors
    /// `text` to the device clipboard.
    case clipboardUpdate(sessionId: UUID, text: String)
    case error(code: Int, message: String)
    /// A pairing code was redeemed: here is the newly minted device token.
    case pairSuccess(token: String, tokenId: String, label: String)

    // MARK: - Wire type strings

    public var typeString: String {
        switch self {
        case .authSuccess:         return "auth_success"
        case .authFailure:         return "auth_failure"
        case .sessionCreated:      return "session_created"
        case .sessionAttached:     return "session_attached"
        case .sessionResumed:      return "session_resumed"
        case .replayComplete:      return "replay_complete"
        case .sessionDetached:     return "session_detached"
        case .sessionTerminated:   return "session_terminated"
        case .sessionExpired:      return "session_expired"
        case .sessionState:        return "session_state"
        case .sessionActivity:     return "session_activity"
        case .sessionStolen:       return "session_stolen"
        case .sessionRenamed:      return "session_renamed"
        case .sessionList:         return "session_list_result"
        case .sessionListAll:      return "session_list_all_result"
        case .resizeAck:           return "resize_ack"
        case .pasteImageResult:    return "paste_image_result"
        case .pong:                return "pong"
        case .pushTokenAck:        return "push_token_ack"
        case .clipboardUpdate:     return "clipboard_update"
        case .error:               return "error"
        case .pairSuccess:         return "pair_success"
        }
    }

    // MARK: - Known type strings

    static let allTypeStrings: Set<String> = [
        "auth_success", "auth_failure",
        "session_created", "session_attached", "session_resumed", "replay_complete", "session_detached",
        "session_terminated", "session_expired", "session_state", "session_activity",
        "session_stolen", "session_renamed",
        "session_list_result", "session_list_all_result",
        "resize_ack", "paste_image_result", "pong", "push_token_ack", "clipboard_update", "error",
        "pair_success"
    ]
}

// MARK: - Codable

extension ServerMessage: Codable {
    private enum PayloadCodingKeys: String, CodingKey {
        case reason, sessionId, cols, rows, state, code, message, sessions, activity, agent, name, success, protocolVersion
        case agentState, title, workingDir, accepted, text, tokenId
        case token, label
    }

    public func encodePayload(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PayloadCodingKeys.self)
        switch self {
        case .authSuccess(let protocolVersion, let tokenId):
            try container.encodeIfPresent(protocolVersion, forKey: .protocolVersion)
            try container.encodeIfPresent(tokenId, forKey: .tokenId)
        case .authFailure(let reason):
            try container.encode(reason, forKey: .reason)
        case .sessionCreated(let sessionId, let cols, let rows):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        case .sessionAttached(let sessionId, let state):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(state, forKey: .state)
        case .sessionResumed(let sessionId):
            try container.encode(sessionId, forKey: .sessionId)
        case .replayComplete(let sessionId):
            try container.encode(sessionId, forKey: .sessionId)
        case .sessionDetached:
            break
        case .sessionTerminated(let sessionId, let reason):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(reason, forKey: .reason)
        case .sessionExpired(let sessionId):
            try container.encode(sessionId, forKey: .sessionId)
        case .sessionState(let sessionId, let state):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(state, forKey: .state)
        case .sessionActivity(let sessionId, let activity, let agent, let agentState, let title, let workingDir):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(activity, forKey: .activity)
            try container.encodeIfPresent(agent, forKey: .agent)
            try container.encodeIfPresent(agentState, forKey: .agentState)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(workingDir, forKey: .workingDir)
        case .sessionStolen(let sessionId):
            try container.encode(sessionId, forKey: .sessionId)
        case .sessionRenamed(let sessionId, let name):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(name, forKey: .name)
        case .sessionList(let sessions):
            try container.encode(sessions, forKey: .sessions)
        case .sessionListAll(let sessions):
            try container.encode(sessions, forKey: .sessions)
        case .resizeAck(let cols, let rows):
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        case .pasteImageResult(let success):
            try container.encode(success, forKey: .success)
        case .pong:
            break
        case .pushTokenAck(let accepted):
            try container.encode(accepted, forKey: .accepted)
        case .clipboardUpdate(let sessionId, let text):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(text, forKey: .text)
        case .error(let code, let message):
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        case .pairSuccess(let token, let tokenId, let label):
            try container.encode(token, forKey: .token)
            try container.encode(tokenId, forKey: .tokenId)
            try container.encode(label, forKey: .label)
        }
    }

    public static func decode(typeString: String, from decoder: Decoder) throws -> ServerMessage {
        let container = try decoder.container(keyedBy: PayloadCodingKeys.self)
        switch typeString {
        case "auth_success":
            let protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
            let tokenId = try container.decodeIfPresent(String.self, forKey: .tokenId)
            return .authSuccess(protocolVersion: protocolVersion, tokenId: tokenId)
        case "auth_failure":
            let reason = try container.decode(String.self, forKey: .reason)
            return .authFailure(reason: reason)
        case "session_created":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let cols = try container.decode(UInt16.self, forKey: .cols)
            let rows = try container.decode(UInt16.self, forKey: .rows)
            return .sessionCreated(sessionId: sessionId, cols: cols, rows: rows)
        case "session_attached":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let state = try container.decode(String.self, forKey: .state)
            return .sessionAttached(sessionId: sessionId, state: state)
        case "session_resumed":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            return .sessionResumed(sessionId: sessionId)
        case "replay_complete":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            return .replayComplete(sessionId: sessionId)
        case "session_detached":
            return .sessionDetached
        case "session_terminated":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let reason = try container.decode(String.self, forKey: .reason)
            return .sessionTerminated(sessionId: sessionId, reason: reason)
        case "session_expired":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            return .sessionExpired(sessionId: sessionId)
        case "session_state":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let state = try container.decode(String.self, forKey: .state)
            return .sessionState(sessionId: sessionId, state: state)
        case "session_activity":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let activity = try container.decode(ActivityState.self, forKey: .activity)
            let agent = try container.decodeIfPresent(String.self, forKey: .agent)
            let agentState = try container.decodeIfPresent(AgentDetectedState.self, forKey: .agentState)
            let title = try container.decodeIfPresent(String.self, forKey: .title)
            let workingDir = try container.decodeIfPresent(String.self, forKey: .workingDir)
            return .sessionActivity(sessionId: sessionId, activity: activity, agent: agent,
                                    agentState: agentState, title: title, workingDir: workingDir)
        case "session_stolen":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            return .sessionStolen(sessionId: sessionId)
        case "session_renamed":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let name = try container.decode(String.self, forKey: .name)
            return .sessionRenamed(sessionId: sessionId, name: name)
        case "session_list_result":
            let sessions = try container.decode([SessionInfo].self, forKey: .sessions)
            return .sessionList(sessions: sessions)
        case "session_list_all_result":
            let sessions = try container.decode([SessionInfo].self, forKey: .sessions)
            return .sessionListAll(sessions: sessions)
        case "resize_ack":
            let cols = try container.decode(UInt16.self, forKey: .cols)
            let rows = try container.decode(UInt16.self, forKey: .rows)
            return .resizeAck(cols: cols, rows: rows)
        case "paste_image_result":
            let success = try container.decode(Bool.self, forKey: .success)
            return .pasteImageResult(success: success)
        case "pong":
            return .pong
        case "push_token_ack":
            return .pushTokenAck(accepted: try container.decode(Bool.self, forKey: .accepted))
        case "clipboard_update":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let text = try container.decode(String.self, forKey: .text)
            return .clipboardUpdate(sessionId: sessionId, text: text)
        case "error":
            let code = try container.decode(Int.self, forKey: .code)
            let message = try container.decode(String.self, forKey: .message)
            return .error(code: code, message: message)
        case "pair_success":
            return .pairSuccess(
                token: try container.decode(String.self, forKey: .token),
                tokenId: try container.decode(String.self, forKey: .tokenId),
                label: try container.decode(String.self, forKey: .label))
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unknown server message type: \(typeString)"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        try encodePayload(to: encoder)
    }

    public init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "ServerMessage must be decoded via MessageEnvelope"
            )
        )
    }
}
