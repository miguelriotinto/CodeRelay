import Foundation
import Crypto
import ClaudeRelayKit

/// APNs token-based-auth configuration. `keyPEM` is the `.p8` contents; the
/// production initializer reads it from `apnsKeyPath`.
public struct APNsConfig: Sendable {
    public let keyPEM: String
    public let keyId: String
    public let teamId: String
    public let bundleId: String
    public let useSandbox: Bool

    public init(keyPEM: String, keyId: String, teamId: String, bundleId: String, useSandbox: Bool) {
        self.keyPEM = keyPEM
        self.keyId = keyId
        self.teamId = teamId
        self.bundleId = bundleId
        self.useSandbox = useSandbox
    }

    /// Loads the `.p8` from disk.
    public init(keyPath: String, keyId: String, teamId: String, bundleId: String, useSandbox: Bool) throws {
        let expanded = NSString(string: keyPath).expandingTildeInPath
        self.keyPEM = try String(contentsOfFile: expanded, encoding: .utf8)
        self.keyId = keyId
        self.teamId = teamId
        self.bundleId = bundleId
        self.useSandbox = useSandbox
    }
}

/// Sends pushes to APNs over HTTP/2 with a token-based (ES256 JWT) auth header.
/// The JWT is cached ~50 min (APNs requires a fresh one at least hourly).
public actor APNsClient: PushSending {
    private let config: APNsConfig
    private let http: PushHTTPExecuting
    private let now: @Sendable () -> Date
    private let privateKey: P256.Signing.PrivateKey

    private var cachedJWT: String?
    private var cachedJWTIssuedAt: Date?
    private static let jwtLifetime: TimeInterval = 50 * 60

    public init(config: APNsConfig, http: PushHTTPExecuting,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.config = config
        self.http = http
        self.now = now
        self.privateKey = try P256.Signing.PrivateKey(pemRepresentation: config.keyPEM)
    }

    private var host: String {
        config.useSandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
    }

    // MARK: - JWT

    /// Builds the APNs provider JWT: header `{alg:ES256,kid}`, claims
    /// `{iss:teamId,iat}`, signed ES256 (raw r||s). Exposed for tests.
    func makeJWT(at date: Date) throws -> String {
        let header = #"{"alg":"ES256","kid":"\#(config.keyId)"}"#
        let iat = Int(date.timeIntervalSince1970)
        let claims = #"{"iss":"\#(config.teamId)","iat":\#(iat)}"#
        let signingInput = Self.base64URL(Data(header.utf8)) + "." + Self.base64URL(Data(claims.utf8))
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        // CryptoKit's rawRepresentation is the 64-byte r||s JWS expects.
        return signingInput + "." + Self.base64URL(signature.rawRepresentation)
    }

    private func currentJWT() throws -> String {
        if let jwt = cachedJWT, let issued = cachedJWTIssuedAt,
           now().timeIntervalSince(issued) < Self.jwtLifetime {
            return jwt
        }
        let issued = now()
        let jwt = try makeJWT(at: issued)
        cachedJWT = jwt
        cachedJWTIssuedAt = issued
        return jwt
    }

    // MARK: - Send

    public func send(deviceToken: String, platform: PushPlatform, topic: String?, title: String,
                     body: String, deepLink: String, collapseKey: String) async -> PushResult {
        do {
            let jwt = try currentJWT()
            // The device reports its own bundle id (iOS vs macOS differ); fall
            // back to the configured default for older clients that omit it.
            let apnsTopic = topic ?? config.bundleId
            let payload: [String: Any] = [
                "aps": [
                    "alert": ["title": title, "body": body],
                    "sound": "default",
                    "thread-id": collapseKey,
                ],
                "deepLink": deepLink,
            ]
            let bodyData = try JSONSerialization.data(withJSONObject: payload)
            let url = "https://\(host)/3/device/\(deviceToken)"
            let headers = [
                ("authorization", "bearer \(jwt)"),
                ("apns-topic", apnsTopic),
                ("apns-push-type", "alert"),
                ("apns-collapse-id", String(collapseKey.prefix(64))),
            ]
            let response = try await http.post(url: url, headers: headers, body: bodyData)
            return Self.interpret(status: response.status, body: response.body)
        } catch {
            return .failed(PushHTTP.redact("\(error)"))
        }
    }

    /// Maps an APNs HTTP status + body to a `PushResult`. 410 (and the
    /// `Unregistered`/`BadDeviceToken` reasons) mean the token is dead.
    static func interpret(status: UInt, body: Data) -> PushResult {
        switch status {
        case 200:
            return .delivered
        case 410:
            return .unregistered
        default:
            let reason = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?
                .flatMap { $0["reason"] as? String } ?? ""
            if reason == "Unregistered" || reason == "BadDeviceToken" { return .unregistered }
            return .failed("apns status \(status)\(reason.isEmpty ? "" : ": \(reason)")")
        }
    }

    // MARK: - Base64URL

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
