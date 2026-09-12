import XCTest
@testable import CodeRelayKit
@testable import CodeRelayServer

final class ConfigValidationTests: XCTestCase {

    // MARK: - Port Validation

    func testValidPorts() throws {
        var config = RelayConfig.default
        try AdminRoutes.applyConfigValue(1024, forKey: "wsPort", to: &config)
        XCTAssertEqual(config.wsPort, 1024)
        try AdminRoutes.applyConfigValue(9200, forKey: "wsPort", to: &config)
        XCTAssertEqual(config.wsPort, 9200)
        try AdminRoutes.applyConfigValue(65535, forKey: "adminPort", to: &config)
        XCTAssertEqual(config.adminPort, 65535)
    }

    func testPortTooLow() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(1023, forKey: "wsPort", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(80, forKey: "wsPort", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(0, forKey: "adminPort", to: &config))
    }

    func testPortTooHigh() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(65536, forKey: "wsPort", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(99999, forKey: "adminPort", to: &config))
    }

    // MARK: - Scrollback Size Validation

    func testValidScrollbackSize() throws {
        var config = RelayConfig.default
        try AdminRoutes.applyConfigValue(1024, forKey: "scrollbackSize", to: &config)
        XCTAssertEqual(config.scrollbackSize, 1024)
        try AdminRoutes.applyConfigValue(1_000_000, forKey: "scrollbackSize", to: &config)
        XCTAssertEqual(config.scrollbackSize, 1_000_000)
    }

    func testScrollbackSizeTooSmall() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(0, forKey: "scrollbackSize", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(1023, forKey: "scrollbackSize", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(-1, forKey: "scrollbackSize", to: &config))
    }

    // MARK: - Detach Timeout Validation

    func testValidDetachTimeout() throws {
        var config = RelayConfig.default
        try AdminRoutes.applyConfigValue(0, forKey: "detachTimeout", to: &config)
        XCTAssertEqual(config.detachTimeout, 0)
        try AdminRoutes.applyConfigValue(3600, forKey: "detachTimeout", to: &config)
        XCTAssertEqual(config.detachTimeout, 3600)
    }

    func testNegativeDetachTimeout() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(-1, forKey: "detachTimeout", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(-100, forKey: "detachTimeout", to: &config))
    }

    // MARK: - Log Level Validation

    func testValidLogLevels() throws {
        var config = RelayConfig.default
        for level in ["trace", "debug", "info", "warning", "error"] {
            try AdminRoutes.applyConfigValue(level, forKey: "logLevel", to: &config)
            XCTAssertEqual(config.logLevel, level)
        }
    }

    func testInvalidLogLevel() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue("invalid", forKey: "logLevel", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue("TRACE", forKey: "logLevel", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue("", forKey: "logLevel", to: &config))
    }

    // MARK: - TLS path validation (C-11)

    func testTLSCertPathMustExist() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(
            "/nonexistent/certificate.pem", forKey: "tlsCert", to: &config))
    }

    func testTLSKeyPathMustExist() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(
            "/nonexistent/private.key", forKey: "tlsKey", to: &config))
    }

    func testTLSPathAcceptsReadableFile() throws {
        var config = RelayConfig.default
        // A file guaranteed to exist and be readable.
        try AdminRoutes.applyConfigValue("/etc/hosts", forKey: "tlsCert", to: &config)
        XCTAssertEqual(config.tlsCert, "/etc/hosts")
    }

    func testEmptyTLSPathClearsField() throws {
        var config = RelayConfig.default
        config.tlsCert = "/etc/hosts"
        // Empty string means "clear this field".
        try AdminRoutes.applyConfigValue("", forKey: "tlsCert", to: &config)
        XCTAssertNil(config.tlsCert)
    }

    func testTLSPathRejectsNonString() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(42, forKey: "tlsCert", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(true, forKey: "tlsKey", to: &config))
    }

    func testTLSPathRejectsUnreadableFile() throws {
        var config = RelayConfig.default
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TLSValidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("cert.pem")
        try Data([0x2D]).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(path.path, forKey: "tlsCert", to: &config))
    }

    // MARK: - bindAll

    func testBindAllAcceptsBool() throws {
        var config = RelayConfig.default
        try AdminRoutes.applyConfigValue(true, forKey: "bindAll", to: &config)
        XCTAssertTrue(config.bindAll)
        try AdminRoutes.applyConfigValue(false, forKey: "bindAll", to: &config)
        XCTAssertFalse(config.bindAll)
    }

    func testBindAllRejectsNonBool() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue("yes", forKey: "bindAll", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(1, forKey: "bindAll", to: &config))
    }

    // MARK: - Unknown Key

    func testUnknownConfigKey() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue("value", forKey: "nonexistent", to: &config))
    }

    // MARK: - Type Mismatch

    func testTypeMismatch() {
        var config = RelayConfig.default
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue("notAnInt", forKey: "wsPort", to: &config))
        XCTAssertThrowsError(try AdminRoutes.applyConfigValue(42, forKey: "logLevel", to: &config))
    }
}
