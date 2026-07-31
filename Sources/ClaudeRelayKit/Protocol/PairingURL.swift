import Foundation

/// The `clauderelay://pair?host=&port=&tls=&code=` deep link produced by
/// `claude-relay setup` and consumed by the apps.
///
/// Parsing and validation live here, in the shared kit, so the server-side
/// producer and all three clients agree on exactly what a valid pairing link
/// is — and so hostile input is rejected in one tested place.
public struct PairingURL: Equatable, Sendable {
    public static let scheme = "clauderelay"
    public static let host = "pair"

    public let host: String
    public let port: UInt16
    public let useTLS: Bool
    /// Always normalized (uppercase, no hyphen).
    public let code: String

    public init(host: String, port: UInt16, useTLS: Bool, code: String) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.code = code
    }

    public var urlString: String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "tls", value: useTLS ? "1" : "0"),
            URLQueryItem(name: "code", value: code)
        ]
        return components.url?.absoluteString ?? ""
    }

    /// The WebSocket URL a client should dial to redeem this code.
    public var wsURL: URL? {
        URL(string: "\(useTLS ? "wss" : "ws")://\(host):\(port)")
    }

    public init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url: url)
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        guard let rawHost = value("host")?.trimmingCharacters(in: .whitespaces),
              !rawHost.isEmpty,
              let rawPort = value("port"), let port = UInt16(rawPort), port >= 1,
              let rawCode = value("code"), let code = PairingCode.normalize(rawCode)
        else { return nil }

        let useTLS = value("tls") == "1"

        // Reject anything that cannot form a usable ws:// URL (spaces, slashes,
        // other RFC 3986-illegal host characters).
        guard URL(string: "\(useTLS ? "wss" : "ws")://\(rawHost):\(port)") != nil,
              rawHost.rangeOfCharacter(from: CharacterSet(charactersIn: " /?#@")) == nil
        else { return nil }

        self.host = rawHost
        self.port = port
        self.useTLS = useTLS
        self.code = code
    }
}
