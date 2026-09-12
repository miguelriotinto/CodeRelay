import XCTest
@testable import CodeRelayClient

final class ConnectionConfigOptionalURLTests: XCTestCase {
    func testWSURLReturnsNilForInvalidHost() {
        let config = ConnectionConfig(
            name: "broken",
            host: "not a valid host with spaces",
            port: 9200
        )
        XCTAssertNil(config.wsURL)
    }

    func testWSURLForValidHost() {
        let config = ConnectionConfig(name: "ok", host: "10.0.0.1", port: 9200)
        XCTAssertEqual(config.wsURL?.absoluteString, "ws://10.0.0.1:9200")
    }

    func testWSURLWithTLSReturnsSecureScheme() {
        let config = ConnectionConfig(name: "secure", host: "10.0.0.1", port: 9200, useTLS: true)
        XCTAssertEqual(config.wsURL?.absoluteString, "wss://10.0.0.1:9200")
    }
}
