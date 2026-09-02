import Foundation

/// The `coderelay://pair?host=&port=&tls=&code=` deep link produced by
/// `claude-relay setup` and consumed by the apps.
///
/// Parsing and validation live here, in the shared kit, so the server-side
/// producer and all three clients agree on exactly what a valid pairing link
/// is — and so hostile input is rejected in one tested place.
public struct PairingURL: Equatable, Sendable {
    /// The URL scheme, renamed from `clauderelay` with the ClaudeRelay →
    /// CodeRelay rebrand.
    ///
    /// Deliberately a hard cutover, not a dual-scheme deprecation: a pairing
    /// code lives five minutes and a session link is generated on demand, so
    /// there is no persisted corpus of old URLs to honour. The cost is that
    /// server and clients must be updated together — a QR from an older
    /// `claude-relay setup` will not open in a client built after this change.
    public static let scheme = "coderelay"
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

    /// Whether `host` can form a usable `ws://host:port` URL.
    ///
    /// Hoisted out of `init?(url:)` so a producer can validate an
    /// operator-supplied host *before* it has a port, a TLS flag, or a minted
    /// code to build a full URL with. Both the producer and the parser ask this
    /// one function, so "what is a valid pairing host" has a single answer.
    public static func isValidHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Reject RFC 3986-illegal host characters before handing the string to
        // URL(string:), which is lenient about some of them.
        guard trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: " /?#@")) == nil else {
            return false
        }
        // The port here is a stand-in: host validity does not depend on it, and
        // any in-range port exercises the same URL parse.
        return URL(string: "ws://\(trimmed):1") != nil
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
        guard Self.isValidHost(rawHost) else { return nil }

        self.host = rawHost
        self.port = port
        self.useTLS = useTLS
        self.code = code
    }
}
