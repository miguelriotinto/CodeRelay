import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client for the CodeRelay admin API (127.0.0.1:adminPort).
public final class AdminClient {
    public let baseURL: URL
    private let session: URLSession

    /// Default per-request timeout. Applied whenever a caller's URLRequest would
    /// otherwise hit the URLSession default (60s) or longer. Shorter overrides
    /// (like isServiceRunning's 3s) are preserved.
    public var requestTimeout: TimeInterval = 10

    public init(port: UInt16 = 9100) {
        // `http://127.0.0.1:<port>` is syntactically valid for any port in
        // `UInt16`, so this URL initialisation cannot actually fail — but
        // `preconditionFailure` surfaces a clear message if macOS ever
        // changes its URL parser semantics, instead of a terse force-unwrap
        // crash.
        guard let base = URL(string: "http://127.0.0.1:\(port)") else {
            preconditionFailure("AdminClient: could not construct base URL for port \(port)")
        }
        self.baseURL = base
        self.session = URLSession.shared
    }

    /// Build a URL from the base and a path that may contain query strings.
    /// Unlike `appendingPathComponent`, this preserves `?` and `&` in paths.
    private func buildURL(_ path: String) -> URL {
        // All callers pass paths from a closed set ("/status", "/tokens/<id>",
        // "/logs?lines=N"); nothing here comes from untrusted input. A failure
        // means the admin surface has a programming error, not a runtime
        // condition to recover from.
        guard let url = URL(string: baseURL.absoluteString + path) else {
            preconditionFailure("AdminClient: invalid URL path \(path)")
        }
        return url
    }

    public func get<T: Decodable>(_ path: String) async throws -> T {
        let url = buildURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await perform(request)
    }

    public func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        let url = buildURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let body = body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request)
    }

    public func put<T: Decodable>(_ path: String, body: any Encodable) async throws -> T {
        let url = buildURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await perform(request)
    }

    public func patch<T: Decodable>(_ path: String, body: any Encodable) async throws -> T {
        let url = buildURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await perform(request)
    }

    public func delete(_ path: String) async throws {
        let url = buildURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (data, response) = try await performRaw(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AdminClientError.serviceNotRunning
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AdminClientError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    public func isServiceRunning() async -> Bool {
        let url = buildURL("/health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        do {
            let (_, response) = try await performRaw(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200..<300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - Private

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await performRaw(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AdminClientError.serviceNotRunning
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AdminClientError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AdminClientError.decodingError(error)
        }
    }

    private func performRaw(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var req = request
        // URLRequest's default timeoutInterval is 60s. Cap at requestTimeout (10s)
        // whenever the caller is at or above that default. Shorter caller-set
        // timeouts (e.g., isServiceRunning's 3s) pass through unchanged.
        if req.timeoutInterval >= 60.0 {
            req.timeoutInterval = requestTimeout
        }
        do {
            return try await session.data(for: req)
        } catch let error as URLError where error.code == .cannotConnectToHost
            || error.code == .networkConnectionLost
            || error.code == .timedOut
            || error.code == .cannotFindHost {
            throw AdminClientError.serviceNotRunning
        }
    }
}

// MARK: - Error

public enum AdminClientError: Error, LocalizedError {
    case serviceNotRunning
    case httpError(statusCode: Int, body: String)
    case decodingError(Error)

    public var errorDescription: String? {
        switch self {
        case .serviceNotRunning:
            return "Service is not running"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .decodingError(let err):
            return "Failed to decode response: \(err)"
        }
    }
}

// MARK: - AnyEncodable helper

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self._encode = { encoder in
            try value.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
