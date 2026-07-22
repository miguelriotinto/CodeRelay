import XCTest
import Foundation
import _CryptoExtras
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

/// A throwaway RSA service-account JSON (base64) for tests only.
private let testServiceAccountB64 = "eyJ0eXBlIjogInNlcnZpY2VfYWNjb3VudCIsICJwcm9qZWN0X2lkIjogInRlc3QtcHJvaiIsICJwcml2YXRlX2tleV9pZCI6ICJraWQiLCAicHJpdmF0ZV9rZXkiOiAiLS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tXG5NSUlFdlFJQkFEQU5CZ2txaGtpRzl3MEJBUUVGQUFTQ0JLY3dnZ1NqQWdFQUFvSUJBUUNPN3VzWWJJSVBPWk1lXG5RYzVZbW94NzJkK3BaeGt2a0hzMEQvSmhFUFIyV0QwcEVYelVwQ044NmNkQlVrNVlQWGNWa3NYRFVhZzZNbXhqXG5rTmdUYSszU25SZHU2L3lKNWRmMzJDdEZqbFZhanJQNDh1SkhBSm80TllqeGg4Qk1kVi93elh0aThWVElNU2lGXG5heG5vTkFYOVB4NVFmajlqY1dab2gvWFBCYlZxdGVIMHNPM1FLQmhFMkdMUlVYb29qS1V4cm5XRUJPSmNKenJyXG5STnRscitzRWRxcTZzbUlQbVQzQk1rWjdBRzZGSEV2RDF4V0t6V3JrdU9NNzlVUTNxTTRBSUJkUkphMHp4YVl2XG40a0N2c0tTODNHUnI5enBjV1NjYlZ0L3lOc1hPSDhqSURScnZEcHg4d296TEMzVThmRHF0WWZ6NnBHOWdWL2pXXG51TWxmRHB3L0FnTUJBQUVDZ2dFQUhucmRnR3BYTzlicnhBYUZjY2lYVDZ2dzhhZU9LK0gwRy9DUW45bGxRRDFsXG40WFdjdUoyK0FadTZ4WGUvUkRyclE1cjJlRVhZQ1gwS054dENzTFdSMUJseXoxRWNtKzE3Smh1ZmNxZzlGR0FkXG5DZWdGajkyVmhZb0pCM1NLOGVNUDBBS0pudHBXMlkvK0U2RjR0MWNzdGNuNWRYSE9vNjZoaDRZQ3lhQnVoUEF0XG52QXpDZG1RemhsYzJuMm54c2NELy90U3p6TnJsWE43aWYzOWdwbGR1eUVHazhtcGdNbWN1c3JxbEpqOStxS2o2XG5FQyszSCtrOWVMeW9OU21oMUVlenlyM0dTSGRidXVXRkg4L1g5c3pwWEIyTklNaXBEMWtLWjA3elZWdUJDL21lXG5yVVorMzdsc3cySGNRYThrcWo2eDdsaHdjcXdsLzJVZ1IxWTF2QXM3aFFLQmdRREZvOUtYUUcybzRRaUNTYVBOXG56b2NBUFRkOFcvcTAvMThseWNETzliVXllamI4THg5NzdjODMyR05mM3Q2bkhQcTV5bmpGaytMSFl2VmczeDYvXG5adWkzTUlEbHRFZjJFd1pWcFg4ejJvQXlLRHJ5OGNkSE1ZaXRMTmNoZE1QQW1xcWs4dkRKenMvZTBkZkpZRlBEXG5CVTVYeU9XVDFVQmZvNVF0V2JZY1M1Ry9Hd0tCZ1FDNUk2a05MOVRzbFBqNVFiUUx2T0VtbWlDRktIZDAvNU9EXG5VSURRRTR2Z3RSckNOVTg5ZmxVdWE3Z1I1K2p3eXYxYUZXWU9HY1RDZTQrUG9NVzR1RzdVaFNHa3N1c0hYVDhQXG45dC9mRytYck5qYWNEUUlUYkxoSWQ1Nk5UM0o3VUhxaDdMekV4OFBJZURGZ05QNU9CUGF4RHV2bGZvT2pZTGM4XG5ILzQyNHAzVnJRS0JnUUNHNDZXaVYzWEFrajNWZGw4VzR3TWV0YWs5OWlUcERYWXArMFhkdXJMOWpZNGpsaUhkXG4ybFBZWUphS1l6a0JRM1VZQXNsa3grYzZnQjdMQzkwWGN5d1hnMEltQkdJczM1VXVOVExZK0NNUW1JYUxNMXI0XG5DeVdtVS9sTU96NHpJUnlnVWJMbmVZQkVLbUlsYmRvZE8yeloyeUpkUUdtY0hLL1FOKzlqNW12Rnl3S0JnRGM5XG45N3hTa0dNRFZJTHpZdWk1dENqVGhtNlZFNGZhbHNadzUrNnVWbWQzUW9PK2FtVjc0NmpWUlhnNlRaeER4WEx5XG52Wi9wZW5kWmJRMjdPQ1FWRENUbmtKRlhQWi9WNS9JNGhMWksyY0RrVFVrazdJQ2xTUnQrYmRYV1pkOTd0UXZKXG4yczJRbWMrZ1pZTkNiTHNVNmhNTTA4Q0hqbm5hYXZKS3pZek04N0dGQW9HQUdjTWpHdkkwR01pNWVYSVp2bzlzXG5WR3pEUm0rbnliZWhmNjdtK0Z1VUxmbjhNOXRvOWFiUlAzZWNWaUpGQld0R0RCMGFrUVluNldoS05PMThsQXFWXG5IMkJFQ1ZlYUZpZXk0RHpuYmlJTFk0QUQ2RXM1L0N4TnZ6dlk5OHpYMDgwNC9RRnJWR1R4a1BldGVhK0tqYWd3XG5vZHdrT21nWXVCNS9keGJrYm1DZWxjcz1cbi0tLS0tRU5EIFBSSVZBVEUgS0VZLS0tLS1cbiIsICJjbGllbnRfZW1haWwiOiAic3ZjQHRlc3QtcHJvai5pYW0uZ3NlcnZpY2VhY2NvdW50LmNvbSIsICJ0b2tlbl91cmkiOiAiaHR0cHM6Ly9vYXV0aDIuZ29vZ2xlYXBpcy5jb20vdG9rZW4ifQ=="

private func testServiceAccount() -> Data { Data(base64Encoded: testServiceAccountB64)! }

/// Mock HTTP that answers the OAuth exchange then the FCM send.
private actor FCMMockHTTP: PushHTTPExecuting {
    private(set) var requests: [(url: String, headers: [(String, String)], body: Data)] = []
    var sendStatus: UInt = 200
    var sendBody = Data()

    func configureSend(status: UInt, body: Data = Data()) { sendStatus = status; sendBody = body }

    func post(url: String, headers: [(String, String)], body: Data) async throws -> PushHTTPResponse {
        requests.append((url, headers, body))
        if url.contains("oauth2") {
            let json = try! JSONSerialization.data(withJSONObject: ["access_token": "ya29.TEST", "expires_in": 3599])
            return PushHTTPResponse(status: 200, headers: [], body: json)
        }
        return PushHTTPResponse(status: sendStatus, headers: [], body: sendBody)
    }
    func all() -> [(url: String, headers: [(String, String)], body: Data)] { requests }
}

final class FCMClientTests: XCTestCase {
    func testOAuthJWTHasCorrectClaimsAndVerifies() async throws {
        let http = FCMMockHTTP()
        let client = try FCMClient(serviceAccountJSON: testServiceAccount(), projectId: "test-proj",
                                   http: http, now: { Date(timeIntervalSince1970: 1000) })
        let jwt = try await client.makeOAuthJWT(at: Date(timeIntervalSince1970: 1000))
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)

        let header = try JSONSerialization.jsonObject(with: Data(base64URLEncoded: parts[0])!) as! [String: String]
        XCTAssertEqual(header["alg"], "RS256")

        let claims = try JSONSerialization.jsonObject(with: Data(base64URLEncoded: parts[1])!) as! [String: Any]
        XCTAssertEqual(claims["iss"] as? String, "svc@test-proj.iam.gserviceaccount.com")
        XCTAssertEqual(claims["scope"] as? String, "https://www.googleapis.com/auth/firebase.messaging")
        XCTAssertEqual(claims["aud"] as? String, "https://oauth2.googleapis.com/token")

        // Verify the RS256 signature against the service account's public key.
        let sa = try JSONSerialization.jsonObject(with: testServiceAccount()) as! [String: Any]
        let priv = try _RSA.Signing.PrivateKey(pemRepresentation: sa["private_key"] as! String)
        let sig = try _RSA.Signing.RSASignature(rawRepresentation: Data(base64URLEncoded: parts[2])!)
        let ok = priv.publicKey.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8),
                                                 padding: .insecurePKCS1v1_5)
        XCTAssertTrue(ok, "RS256 signature must verify against the service-account public key")
    }

    func testSendExchangesOAuthThenPostsV1Message() async throws {
        let http = FCMMockHTTP()
        await http.configureSend(status: 200)
        let client = try FCMClient(serviceAccountJSON: testServiceAccount(), projectId: "test-proj", http: http)
        let result = await client.send(deviceToken: "dev1", platform: .fcm, title: "demo",
                                       body: "blocked", deepLink: "clauderelay://session/x",
                                       collapseKey: "ws_hash")
        XCTAssertEqual(result, .delivered)

        let reqs = await http.all()
        XCTAssertEqual(reqs.count, 2, "one OAuth exchange + one send")
        XCTAssertTrue(reqs[0].url.contains("oauth2.googleapis.com/token"))
        XCTAssertEqual(reqs[1].url, "https://fcm.googleapis.com/v1/projects/test-proj/messages:send")
        XCTAssertTrue(reqs[1].headers.contains { $0.0 == "authorization" && $0.1 == "Bearer ya29.TEST" })

        let msg = (try JSONSerialization.jsonObject(with: reqs[1].body) as! [String: Any])["message"] as! [String: Any]
        XCTAssertEqual(msg["token"] as? String, "dev1")
        XCTAssertEqual((msg["notification"] as? [String: Any])?["title"] as? String, "demo")
        XCTAssertEqual((msg["data"] as? [String: Any])?["deepLink"] as? String, "clauderelay://session/x")
        XCTAssertEqual((msg["android"] as? [String: Any])?["collapse_key"] as? String, "ws_hash")
    }

    func testUnregisteredMapping() {
        let body = try! JSONSerialization.data(withJSONObject: ["error": ["status": "UNREGISTERED"]])
        XCTAssertEqual(FCMClient.interpret(status: 404, body: body), .unregistered)
    }

    func testCachesAccessTokenAcrossSends() async throws {
        let http = FCMMockHTTP()
        await http.configureSend(status: 200)
        let client = try FCMClient(serviceAccountJSON: testServiceAccount(), projectId: "test-proj", http: http)
        _ = await client.send(deviceToken: "d1", platform: .fcm, title: "t", body: "b", deepLink: "l", collapseKey: "k")
        _ = await client.send(deviceToken: "d2", platform: .fcm, title: "t", body: "b", deepLink: "l", collapseKey: "k")
        let oauthCalls = await http.all().filter { $0.url.contains("oauth2") }.count
        XCTAssertEqual(oauthCalls, 1, "access token should be cached, not re-minted per send")
    }
}
