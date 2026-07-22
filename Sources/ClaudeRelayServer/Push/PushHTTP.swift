import Foundation
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import Logging

/// A single HTTP response with a size-capped body.
public struct PushHTTPResponse: Sendable {
    public let status: UInt
    public let headers: [(String, String)]
    public let body: Data
    public init(status: UInt, headers: [(String, String)], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The minimal HTTP capability the push clients need. Abstracted so tests can
/// inject a mock without a live socket.
public protocol PushHTTPExecuting: Sendable {
    func post(url: String, headers: [(String, String)], body: Data) async throws -> PushHTTPResponse
}

/// Bounded, retrying HTTP/2 POST wrapper over AsyncHTTPClient for APNs/FCM:
/// caps the response body, enforces a per-request timeout, retries 429/5xx with
/// backoff (honoring `Retry-After`), and never lets a leaked `authorization`
/// header value reach a thrown error.
public struct PushHTTP: PushHTTPExecuting {
    private let client: HTTPClient
    private let maxBodyBytes: Int
    private let requestTimeout: TimeAmount
    private let maxRetries: Int

    public init(client: HTTPClient, maxBodyBytes: Int = 64 * 1024,
                requestTimeout: TimeAmount = .seconds(10), maxRetries: Int = 2) {
        self.client = client
        self.maxBodyBytes = maxBodyBytes
        self.requestTimeout = requestTimeout
        self.maxRetries = maxRetries
    }

    public func post(url: String, headers: [(String, String)], body: Data) async throws -> PushHTTPResponse {
        var attempt = 0
        while true {
            var request = HTTPClientRequest(url: url)
            request.method = .POST
            for (name, value) in headers { request.headers.add(name: name, value: value) }
            request.body = .bytes(ByteBuffer(bytes: body))

            do {
                let response = try await client.execute(request, timeout: requestTimeout)
                let status = UInt(response.status.code)
                // Retry transient failures with backoff.
                if (status == 429 || status >= 500), attempt < maxRetries {
                    attempt += 1
                    let retryAfter = response.headers.first(name: "retry-after").flatMap { UInt64($0) }
                    try await backoff(attempt: attempt, retryAfterSeconds: retryAfter)
                    continue
                }
                let collected = try await response.body.collect(upTo: maxBodyBytes)
                let data = Data(buffer: collected)
                let headerPairs = response.headers.map { ($0.name, $0.value) }
                return PushHTTPResponse(status: status, headers: headerPairs, body: data)
            } catch {
                // Body-too-large or transport error. Retry transport errors a
                // bounded number of times; otherwise surface a redacted message.
                if attempt < maxRetries, !(error is PushHTTPError) {
                    attempt += 1
                    try await backoff(attempt: attempt, retryAfterSeconds: nil)
                    continue
                }
                throw PushHTTPError.transport(Self.redact("\(error)"))
            }
        }
    }

    private func backoff(attempt: Int, retryAfterSeconds: UInt64?) async throws {
        let seconds = retryAfterSeconds ?? UInt64(pow(2.0, Double(attempt - 1)))  // 1s, 2s, …
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
    }

    /// Strip any bearer token so credentials never land in logs/errors.
    static func redact(_ text: String) -> String {
        var result = text
        if let range = result.range(of: #"(?i)bearer\s+[A-Za-z0-9._\-]+"#, options: .regularExpression) {
            result.replaceSubrange(range, with: "bearer <redacted>")
        }
        return result
    }
}

public enum PushHTTPError: Error, Sendable {
    case transport(String)
}
