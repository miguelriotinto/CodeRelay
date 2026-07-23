import Foundation
import Crypto
import _CryptoExtras
import ClaudeRelayKit

/// Sends pushes via Firebase Cloud Messaging HTTP v1. Mints an OAuth2 access
/// token from a service-account key (RS256 JWT → token endpoint), caches it
/// ~55 min, then POSTs to the v1 send endpoint.
public actor FCMClient: PushSending {
    private let clientEmail: String
    private let privateKey: _RSA.Signing.PrivateKey
    private let tokenURI: String
    private let projectId: String
    private let http: PushHTTPExecuting
    private let now: @Sendable () -> Date

    private var cachedAccessToken: String?
    private var cachedTokenExpiry: Date?
    private static let tokenLifetime: TimeInterval = 55 * 60
    private static let scope = "https://www.googleapis.com/auth/firebase.messaging"

    /// Parse a Google service-account JSON (client_email, private_key, token_uri).
    public init(serviceAccountJSON: Data, projectId: String, http: PushHTTPExecuting,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard let obj = try JSONSerialization.jsonObject(with: serviceAccountJSON) as? [String: Any],
              let email = obj["client_email"] as? String,
              let pem = obj["private_key"] as? String else {
            throw FCMError.invalidServiceAccount
        }
        self.clientEmail = email
        self.privateKey = try _RSA.Signing.PrivateKey(pemRepresentation: pem)
        self.tokenURI = (obj["token_uri"] as? String) ?? "https://oauth2.googleapis.com/token"
        self.projectId = projectId
        self.http = http
        self.now = now
    }

    public init(serviceAccountPath: String, projectId: String, http: PushHTTPExecuting,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        let expanded = NSString(string: serviceAccountPath).expandingTildeInPath
        let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        try self.init(serviceAccountJSON: data, projectId: projectId, http: http, now: now)
    }

    // MARK: - OAuth JWT

    /// Builds the RS256 OAuth assertion JWT. Exposed for tests.
    func makeOAuthJWT(at date: Date) throws -> String {
        let header = #"{"alg":"RS256","typ":"JWT"}"#
        let iat = Int(date.timeIntervalSince1970)
        let exp = iat + 3600
        let claims = "{\"iss\":\"\(clientEmail)\",\"scope\":\"\(Self.scope)\"," +
            "\"aud\":\"\(tokenURI)\",\"iat\":\(iat),\"exp\":\(exp)}"
        let signingInput = APNsClient.base64URL(Data(header.utf8)) + "." +
            APNsClient.base64URL(Data(claims.utf8))
        let signature = try privateKey.signature(for: Data(signingInput.utf8), padding: .insecurePKCS1v1_5)
        return signingInput + "." + APNsClient.base64URL(signature.rawRepresentation)
    }

    private func accessToken() async throws -> String {
        if let token = cachedAccessToken, let expiry = cachedTokenExpiry, now() < expiry {
            return token
        }
        let jwt = try makeOAuthJWT(at: now())
        let form = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)"
        let response = try await http.post(
            url: tokenURI,
            headers: [("content-type", "application/x-www-form-urlencoded")],
            body: Data(form.utf8))
        guard response.status == 200,
              let obj = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let token = obj["access_token"] as? String else {
            throw FCMError.oauthFailed(status: response.status)
        }
        cachedAccessToken = token
        cachedTokenExpiry = now().addingTimeInterval(Self.tokenLifetime)
        return token
    }

    // MARK: - Send

    public func send(deviceToken: String, platform: PushPlatform, topic: String?, title: String,
                     body: String, deepLink: String, collapseKey: String) async -> PushResult {
        // `topic` is APNs-only (per-app bundle id); FCM addresses the device
        // token directly, so it is intentionally ignored here.
        do {
            let token = try await accessToken()
            let message: [String: Any] = [
                "message": [
                    "token": deviceToken,
                    "notification": ["title": title, "body": body],
                    "data": ["deepLink": deepLink],
                    "android": ["collapse_key": collapseKey],
                ],
            ]
            let bodyData = try JSONSerialization.data(withJSONObject: message)
            let url = "https://fcm.googleapis.com/v1/projects/\(projectId)/messages:send"
            let response = try await http.post(
                url: url,
                headers: [("authorization", "Bearer \(token)"), ("content-type", "application/json")],
                body: bodyData)
            return Self.interpret(status: response.status, body: response.body)
        } catch {
            return .failed(PushHTTP.redact("\(error)"))
        }
    }

    /// Maps an FCM v1 status + body to a `PushResult`. UNREGISTERED / 404 mean
    /// the token is dead.
    static func interpret(status: UInt, body: Data) -> PushResult {
        if status == 200 { return .delivered }
        let errorStatus = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["status"] as? String } ?? ""
        if status == 404 || errorStatus == "UNREGISTERED" || errorStatus == "NOT_FOUND" {
            return .unregistered
        }
        return .failed("fcm status \(status)\(errorStatus.isEmpty ? "" : ": \(errorStatus)")")
    }
}

public enum FCMError: Error, Sendable {
    case invalidServiceAccount
    case oauthFailed(status: UInt)
}
