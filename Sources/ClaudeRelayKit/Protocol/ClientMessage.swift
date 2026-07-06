import Foundation

/// Messages sent from the client to the server.
public enum ClientMessage: Equatable, Sendable {
    case authRequest(token: String, protocolVersion: Int? = nil)
    case sessionCreate(name: String? = nil, cols: UInt16? = nil, rows: UInt16? = nil)
    case sessionAttach(sessionId: UUID)
    /// Resume a detached session. `skipReplay` (defaults to false) lets the
    /// client opt out of receiving the server's ring-buffer replay when it
    /// already has a live terminal with full scrollback for this session —
    /// e.g. when switching between tabs on the same device.
    case sessionResume(sessionId: UUID, skipReplay: Bool = false)
    case sessionDetach
    case sessionTerminate(sessionId: UUID)
    case sessionList
    case sessionListAll
    case sessionRename(sessionId: UUID, name: String)
    case resize(cols: UInt16, rows: UInt16)
    /// Ask the server to deliver SIGWINCH to the attached session's foreground
    /// process group so full-screen apps re-emit their whole screen. Used by the
    /// apps' tap-to-redraw: client-side repaints can't fix a corrupted grid —
    /// only the running application can, by redrawing from its own state.
    case refresh
    case pasteImage(data: String)
    case ping

    // MARK: - Wire type strings

    public var typeString: String {
        switch self {
        case .authRequest:       return "auth_request"
        case .sessionCreate:  return "session_create"
        case .sessionAttach:  return "session_attach"
        case .sessionResume:  return "session_resume"
        case .sessionDetach:     return "session_detach"
        case .sessionTerminate:  return "session_terminate"
        case .sessionList:       return "session_list"
        case .sessionListAll:    return "session_list_all"
        case .sessionRename:     return "session_rename"
        case .resize:         return "resize"
        case .refresh:        return "refresh"
        case .pasteImage:     return "paste_image"
        case .ping:           return "ping"
        }
    }

    // MARK: - Known type strings

    static let allTypeStrings: Set<String> = [
        "auth_request",
        "session_create", "session_attach", "session_resume", "session_detach",
        "session_terminate", "session_list", "session_list_all", "session_rename",
        "resize", "refresh", "paste_image", "ping"
    ]
}

// MARK: - Codable

extension ClientMessage: Codable {
    private enum PayloadCodingKeys: String, CodingKey {
        case token, sessionId, cols, rows, name, data, protocolVersion, skipReplay
    }

    public func encodePayload(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PayloadCodingKeys.self)
        switch self {
        case .authRequest(let token, let protocolVersion):
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(protocolVersion, forKey: .protocolVersion)
        case .sessionCreate(let name, let cols, let rows):
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(cols, forKey: .cols)
            try container.encodeIfPresent(rows, forKey: .rows)
        case .sessionAttach(let sessionId):
            try container.encode(sessionId, forKey: .sessionId)
        case .sessionResume(let sessionId, let skipReplay):
            try container.encode(sessionId, forKey: .sessionId)
            if skipReplay {
                try container.encode(true, forKey: .skipReplay)
            }
        case .sessionDetach:
            break
        case .sessionTerminate(let sessionId):
            try container.encode(sessionId, forKey: .sessionId)
        case .sessionList:
            break
        case .sessionListAll:
            break
        case .sessionRename(let sessionId, let name):
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(name, forKey: .name)
        case .resize(let cols, let rows):
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        case .refresh:
            break
        case .pasteImage(let data):
            try container.encode(data, forKey: .data)
        case .ping:
            break
        }
    }

    public static func decode(typeString: String, from decoder: Decoder) throws -> ClientMessage {
        let container = try decoder.container(keyedBy: PayloadCodingKeys.self)
        switch typeString {
        case "auth_request":
            let token = try container.decode(String.self, forKey: .token)
            let protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
            return .authRequest(token: token, protocolVersion: protocolVersion)
        case "session_create":
            let name = try container.decodeIfPresent(String.self, forKey: .name)
            let cols = try container.decodeIfPresent(UInt16.self, forKey: .cols)
            let rows = try container.decodeIfPresent(UInt16.self, forKey: .rows)
            return .sessionCreate(name: name, cols: cols, rows: rows)
        case "session_attach":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            return .sessionAttach(sessionId: sessionId)
        case "session_resume":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let skipReplay = try container.decodeIfPresent(Bool.self, forKey: .skipReplay) ?? false
            return .sessionResume(sessionId: sessionId, skipReplay: skipReplay)
        case "session_detach":
            return .sessionDetach
        case "session_terminate":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            return .sessionTerminate(sessionId: sessionId)
        case "session_list":
            return .sessionList
        case "session_list_all":
            return .sessionListAll
        case "session_rename":
            let sessionId = try container.decode(UUID.self, forKey: .sessionId)
            let name = try container.decode(String.self, forKey: .name)
            return .sessionRename(sessionId: sessionId, name: name)
        case "resize":
            let cols = try container.decode(UInt16.self, forKey: .cols)
            let rows = try container.decode(UInt16.self, forKey: .rows)
            return .resize(cols: cols, rows: rows)
        case "refresh":
            return .refresh
        case "paste_image":
            let data = try container.decode(String.self, forKey: .data)
            return .pasteImage(data: data)
        case "ping":
            return .ping
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unknown client message type: \(typeString)"
                )
            )
        }
    }

    // Default Codable conformance delegates through MessageEnvelope.
    // These are here to satisfy the protocol but envelope is the primary entry point.
    public func encode(to encoder: Encoder) throws {
        try encodePayload(to: encoder)
    }

    public init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "ClientMessage must be decoded via MessageEnvelope"
            )
        )
    }
}
