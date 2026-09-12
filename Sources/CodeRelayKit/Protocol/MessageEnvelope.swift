import Foundation

/// A wire-format envelope that wraps either a `ClientMessage` or `ServerMessage`.
///
/// Encodes to: `{"type":"<message_type>","payload":{...}}`
///
/// Thread-safe: both associated types conform to `Sendable`, and the
/// `typeOrigin` lookup table is immutable after initialization.
public enum MessageEnvelope: Equatable, Sendable {
    case client(ClientMessage)
    case server(ServerMessage)
}

// MARK: - Codable

extension MessageEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    private enum MessageOrigin {
        case client, server
    }

    /// Single lookup table for all type strings — avoids two Set lookups per decode.
    private static let typeOrigin: [String: MessageOrigin] = {
        var map = [String: MessageOrigin]()
        for ts in ClientMessage.allTypeStrings { map[ts] = .client }
        for ts in ServerMessage.allTypeStrings { map[ts] = .server }
        return map
    }()

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .client(let message):
            try container.encode(message.typeString, forKey: .type)
            try container.encode(message, forKey: .payload)
        case .server(let message):
            try container.encode(message.typeString, forKey: .type)
            try container.encode(message, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeString = try container.decode(String.self, forKey: .type)

        switch Self.typeOrigin[typeString] {
        case .client:
            let payloadDecoder = try container.superDecoder(forKey: .payload)
            let message = try ClientMessage.decode(typeString: typeString, from: payloadDecoder)
            self = .client(message)
        case .server:
            let payloadDecoder = try container.superDecoder(forKey: .payload)
            let message = try ServerMessage.decode(typeString: typeString, from: payloadDecoder)
            self = .server(message)
        case nil:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown message type: \(typeString)"
            )
        }
    }
}
