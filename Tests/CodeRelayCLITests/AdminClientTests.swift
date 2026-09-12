import XCTest
@testable import CodeRelayCLI

final class AdminClientTests: XCTestCase {

    // MARK: - URL Construction

    func testBaseURLConstruction() {
        let client = AdminClient(port: 9100)
        XCTAssertEqual(client.baseURL.absoluteString, "http://127.0.0.1:9100")
    }

    func testBaseURLWithCustomPort() {
        let client = AdminClient(port: 8080)
        XCTAssertEqual(client.baseURL.absoluteString, "http://127.0.0.1:8080")
    }

    func testBaseURLMinPort() {
        let client = AdminClient(port: 1)
        XCTAssertEqual(client.baseURL.absoluteString, "http://127.0.0.1:1")
    }

    func testBaseURLMaxPort() {
        let client = AdminClient(port: 65535)
        XCTAssertEqual(client.baseURL.absoluteString, "http://127.0.0.1:65535")
    }

    // MARK: - isServiceRunning

    func testIsServiceRunningReturnsFalseWhenNoServer() async {
        // Port 1 is unlikely to have a server listening
        let client = AdminClient(port: 1)
        let running = await client.isServiceRunning()
        XCTAssertFalse(running, "Should return false when no server is listening")
    }

    // MARK: - Error types

    func testServiceNotRunningErrorDescription() {
        let error = AdminClientError.serviceNotRunning
        XCTAssertEqual(error.errorDescription, "Service is not running")
    }

    func testHTTPErrorDescription() {
        let error = AdminClientError.httpError(statusCode: 404, body: "not found")
        XCTAssertEqual(error.errorDescription, "HTTP 404: not found")
    }

    func testDecodingErrorDescription() {
        let underlying = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad json"])
        let error = AdminClientError.decodingError(underlying)
        XCTAssertTrue(error.errorDescription?.contains("Failed to decode") ?? false)
    }

    // MARK: - Request timeout

    func testDefaultRequestTimeout() {
        let client = AdminClient(port: 9100)
        XCTAssertEqual(client.requestTimeout, 10)
    }
}
