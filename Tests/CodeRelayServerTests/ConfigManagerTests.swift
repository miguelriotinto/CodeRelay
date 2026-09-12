import XCTest
@testable import CodeRelayServer
@testable import CodeRelayKit

final class ConfigManagerTests: XCTestCase {

    func testLoadSucceeds() throws {
        let config = try ConfigManager.load()
        // Verify config loads without error and has valid port values
        XCTAssertGreaterThan(config.wsPort, 0)
        XCTAssertGreaterThan(config.adminPort, 0)
        XCTAssertGreaterThanOrEqual(config.detachTimeout, 0)
        XCTAssertGreaterThan(config.scrollbackSize, 0)
        XCTAssertFalse(config.logLevel.isEmpty)
    }

    func testRelayConfigCodableRoundTrip() throws {
        let original = RelayConfig(
            wsPort: 8080,
            adminPort: 8081,
            detachTimeout: 600,
            scrollbackSize: 131072,
            tlsCert: "/path/to/cert.pem",
            tlsKey: "/path/to/key.pem",
            logLevel: "debug"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RelayConfig.self, from: data)

        XCTAssertEqual(decoded.wsPort, original.wsPort)
        XCTAssertEqual(decoded.adminPort, original.adminPort)
        XCTAssertEqual(decoded.detachTimeout, original.detachTimeout)
        XCTAssertEqual(decoded.scrollbackSize, original.scrollbackSize)
        XCTAssertEqual(decoded.tlsCert, original.tlsCert)
        XCTAssertEqual(decoded.tlsKey, original.tlsKey)
        XCTAssertEqual(decoded.logLevel, original.logLevel)
    }

    func testRelayConfigDefaultValues() {
        let config = RelayConfig.default
        XCTAssertEqual(config.wsPort, 9200)
        XCTAssertEqual(config.adminPort, 9100)
        XCTAssertEqual(config.detachTimeout, 0)
        XCTAssertTrue(config.bindAll, "Default: accept connections from any interface")
    }

    func testBindAllCodableRoundTrip() throws {
        // Round-trip both possible values so we don't lose fidelity either way.
        for value in [true, false] {
            let original = RelayConfig(bindAll: value)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(RelayConfig.self, from: data)
            XCTAssertEqual(decoded.bindAll, value)
        }
    }

    /// Older configs on disk predate the bindAll key. Decoding must succeed
    /// and fall back to the default (accept any interface) so upgrading users
    /// keep the previous behavior.
    func testLegacyConfigWithoutBindAllDecodesAsBindAll() throws {
        let legacyJSON = """
        {"wsPort":9200,"adminPort":9100,"detachTimeout":0,"scrollbackSize":524288,"logLevel":"info","maxSessionsPerToken":50}
        """
        let decoded = try JSONDecoder().decode(RelayConfig.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(decoded.bindAll, "Missing key must default to network-reachable (previous behavior)")
    }

    func testConfigDirectoryPath() {
        let dir = RelayConfig.configDirectory
        XCTAssertTrue(dir.path.hasSuffix(".claude-relay"))
    }

    func testConfigFilePath() {
        let file = RelayConfig.configFile
        XCTAssertTrue(file.path.hasSuffix("config.json"))
    }

    func testTokensFilePath() {
        let file = RelayConfig.tokensFile
        XCTAssertTrue(file.path.hasSuffix("tokens.json"))
    }
}
