import XCTest
@testable import ClaudeRelayKit

final class RelayConfigTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - Default Values

    func testDefaultValues() {
        let config = RelayConfig.default
        XCTAssertEqual(config.wsPort, 9200)
        XCTAssertEqual(config.adminPort, 9100)
        XCTAssertEqual(config.detachTimeout, 0)
        XCTAssertEqual(config.scrollbackSize, 524288)
        XCTAssertNil(config.tlsCert)
        XCTAssertNil(config.tlsKey)
        XCTAssertEqual(config.logLevel, "info")
        XCTAssertEqual(config.maxSessionsPerToken, 50)
        XCTAssertTrue(config.bindAll)
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let config = RelayConfig(
            wsPort: 8080,
            adminPort: 8081,
            detachTimeout: 300,
            scrollbackSize: 1048576,
            tlsCert: "/etc/cert.pem",
            tlsKey: "/etc/key.pem",
            logLevel: "debug",
            maxSessionsPerToken: 100,
            bindAll: false
        )

        let data = try encoder.encode(config)
        let decoded = try decoder.decode(RelayConfig.self, from: data)

        XCTAssertEqual(decoded.wsPort, 8080)
        XCTAssertEqual(decoded.adminPort, 8081)
        XCTAssertEqual(decoded.detachTimeout, 300)
        XCTAssertEqual(decoded.scrollbackSize, 1048576)
        XCTAssertEqual(decoded.tlsCert, "/etc/cert.pem")
        XCTAssertEqual(decoded.tlsKey, "/etc/key.pem")
        XCTAssertEqual(decoded.logLevel, "debug")
        XCTAssertEqual(decoded.maxSessionsPerToken, 100)
        XCTAssertFalse(decoded.bindAll)
    }

    func testDecodingMissingOptionalFieldsUsesNil() throws {
        let json = """
        {"wsPort":9200,"adminPort":9100,"detachTimeout":0,"scrollbackSize":524288,"logLevel":"info","maxSessionsPerToken":50,"bindAll":true}
        """
        let config = try decoder.decode(RelayConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.tlsCert)
        XCTAssertNil(config.tlsKey)
    }

    func testDecodingMissingNewFieldsUsesDefaults() throws {
        // Simulates an old config.json that lacks maxSessionsPerToken and bindAll
        let json = """
        {"wsPort":9200,"adminPort":9100,"detachTimeout":0,"scrollbackSize":524288,"logLevel":"info"}
        """
        let config = try decoder.decode(RelayConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.maxSessionsPerToken, 50, "Missing maxSessionsPerToken should default to 50")
        XCTAssertTrue(config.bindAll, "Missing bindAll should default to true")
    }

    func testDecodingEmptyObjectUsesAllDefaults() throws {
        let json = "{}"
        let config = try decoder.decode(RelayConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.wsPort, 9200)
        XCTAssertEqual(config.adminPort, 9100)
        XCTAssertEqual(config.detachTimeout, 0)
        XCTAssertEqual(config.scrollbackSize, 524288)
        XCTAssertNil(config.tlsCert)
        XCTAssertNil(config.tlsKey)
        XCTAssertEqual(config.logLevel, "info")
        XCTAssertEqual(config.maxSessionsPerToken, 50)
        XCTAssertTrue(config.bindAll)
    }

    // MARK: - Static Path Properties

    func testConfigDirectoryPath() {
        let path = RelayConfig.configDirectory.path
        XCTAssertTrue(path.hasSuffix(".claude-relay"), "Config directory should end with .claude-relay, got: \(path)")
    }

    func testConfigFilePath() {
        let path = RelayConfig.configFile.path
        XCTAssertTrue(path.contains(".claude-relay"), "Config file should be inside .claude-relay directory")
        XCTAssertTrue(path.hasSuffix("config.json"), "Config file should be config.json")
    }

    func testTokensFilePath() {
        let path = RelayConfig.tokensFile.path
        XCTAssertTrue(path.contains(".claude-relay"), "Tokens file should be inside .claude-relay directory")
        XCTAssertTrue(path.hasSuffix("tokens.json"), "Tokens file should be tokens.json")
    }

    // MARK: - Port Boundary Values

    func testMinimumPortValues() throws {
        let json = """
        {"wsPort":1,"adminPort":1}
        """
        let config = try decoder.decode(RelayConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.wsPort, 1)
        XCTAssertEqual(config.adminPort, 1)
    }

    func testMaximumPortValues() throws {
        let json = """
        {"wsPort":65535,"adminPort":65535}
        """
        let config = try decoder.decode(RelayConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.wsPort, 65535)
        XCTAssertEqual(config.adminPort, 65535)
    }

    // MARK: - Push configuration

    func testPushDefaultsAreOff() {
        let config = RelayConfig.default
        XCTAssertFalse(config.pushEnabled)
        XCTAssertFalse(config.pushNotifyOnFinished)
        XCTAssertNil(config.apnsKeyPath)
        XCTAssertNil(config.fcmServiceAccountPath)
        XCTAssertFalse(config.apnsUseSandbox)
    }

    func testPushKeysRoundTripThroughCustomDecoder() throws {
        let json = """
        {"pushEnabled":true,"pushNotifyOnFinished":true,"apnsKeyPath":"/k.p8",\
        "apnsKeyId":"KID","apnsTeamId":"TEAM","apnsBundleId":"com.claude.relay",\
        "apnsUseSandbox":true,"fcmServiceAccountPath":"/sa.json","fcmProjectId":"proj"}
        """
        let config = try decoder.decode(RelayConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.pushEnabled)
        XCTAssertTrue(config.pushNotifyOnFinished)
        XCTAssertEqual(config.apnsKeyPath, "/k.p8")
        XCTAssertEqual(config.apnsKeyId, "KID")
        XCTAssertEqual(config.apnsTeamId, "TEAM")
        XCTAssertEqual(config.apnsBundleId, "com.claude.relay")
        XCTAssertTrue(config.apnsUseSandbox)
        XCTAssertEqual(config.fcmServiceAccountPath, "/sa.json")
        XCTAssertEqual(config.fcmProjectId, "proj")
    }

    func testConfigWithoutPushKeysStillDecodes() throws {
        // Back-compat: an existing config with no push keys decodes fine.
        let config = try decoder.decode(RelayConfig.self, from: Data(#"{"wsPort":9200}"#.utf8))
        XCTAssertFalse(config.pushEnabled)
        XCTAssertNil(config.apnsKeyPath)
    }

    // MARK: - tlsEnabled computed property

    func testTLSEnabledOnlyWhenBothCertAndKeyArePresent() {
        var config = RelayConfig.default
        XCTAssertFalse(config.tlsEnabled, "no cert/key → false")

        config.tlsCert = "/path/to/cert.pem"
        XCTAssertFalse(config.tlsEnabled, "cert without key → false")

        config.tlsKey = "/path/to/key.pem"
        XCTAssertTrue(config.tlsEnabled, "cert + key → true")

        config.tlsCert = nil
        XCTAssertFalse(config.tlsEnabled, "key without cert → false")

        config.tlsCert = ""
        config.tlsKey = ""
        XCTAssertFalse(config.tlsEnabled, "empty paths → false")
    }
}
