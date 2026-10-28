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

    // MARK: - Multi-server fields (spec §9)

    func testPreFeatureBookmarkDecodesEnabledWithNoIdentity() throws {
        let json = #"{"id":"0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D","name":"Studio","host":"studio.local","port":9200,"useTLS":false}"#
        let config = try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.enabled, "bookmarks saved before the feature stay usable")
        XCTAssertNil(config.instanceId)
        XCTAssertNil(config.displayName)
    }

    func testNewFieldsRoundTrip() throws {
        var config = ConnectionConfig(name: "Studio", host: "studio.local")
        config.enabled = false
        config.instanceId = UUID(uuidString: "0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D")
        config.displayName = "studio"
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertFalse(decoded.enabled)
    }

    func testWrongTypedOptionalFieldsFallBackToDefaultsInsteadOfFailing() throws {
        // A field a future build stored in another shape must not throw: the list
        // is decoded all-or-nothing, so one bad field would wipe every bookmark.
        let json = """
        {"id":"\(UUID().uuidString)","name":"n","host":"h","port":9200,"useTLS":false,
         "enabled":"yes","instanceId":12,"displayName":false}
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(ConnectionConfig.self, from: json)
        XCTAssertTrue(c.enabled)
        XCTAssertNil(c.instanceId)
        XCTAssertNil(c.displayName)
    }

    func testMemberwiseInitDefaultsToEnabled() {
        XCTAssertTrue(ConnectionConfig(name: "a", host: "b").enabled)
    }
}
