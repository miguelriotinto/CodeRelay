import XCTest
@testable import ClaudeRelayCLI
import ClaudeRelayKit

/// Covers `claude-relay config validate`'s port checks.
///
/// Regression context: the bound was 1–65535 while the admin API enforces
/// 1024–65535 on writes (`AdminRoutes.validatePort`), so a privileged port like
/// 80 was reported as valid even though `config set` refuses it.
///
/// The checks also used `if let port = Int(value), port < 1 ...`, so a
/// **non-numeric** port never entered the comparison and exited as success.
/// That path is unreachable today — `/config` encodes a typed `RelayConfig`
/// with `UInt16` ports — so these tests pin it as defence in depth, not as a
/// reproduction of a user-visible failure.
final class ConfigValidateTests: XCTestCase {

    private func validate(_ value: ConfigValue?, name: String = "wsPort") -> (port: Int?, errors: [String]) {
        var errors: [String] = []
        let port = ConfigValidateCommand.validatePort(value, name: name, errors: &errors)
        return (port, errors)
    }

    // MARK: - Non-numeric

    func testNonNumericPortIsReported() {
        let result = validate(.string("abc"))
        XCTAssertNil(result.port)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(
            result.errors[0].contains("must be an integer"),
            "Expected an integer-parse error, got \(result.errors)"
        )
    }

    func testEmptyStringPortIsReported() {
        let result = validate(.string(""))
        XCTAssertNil(result.port)
        XCTAssertEqual(result.errors.count, 1)
    }

    func testBoolPortIsReported() {
        let result = validate(.bool(true))
        XCTAssertNil(result.port)
        XCTAssertEqual(result.errors.count, 1)
    }

    // MARK: - Shared bound

    /// The bound must come from `RelayConfig.portRange`, not from a local copy.
    /// Two call sites checked ports with their own `1024...65535` literal
    /// (`ConfigSetCommand`, `AdminRoutes.validatePort`) while this one compared
    /// against `1` and `65535` and so blessed privileged ports; pinning the
    /// derivation is what stops it drifting again, since a doc comment cannot.
    func testRangeIsDerivedFromSharedRelayConfigBound() {
        XCTAssertEqual(ConfigValidateCommand.minPort, RelayConfig.portRange.lowerBound)
        XCTAssertEqual(ConfigValidateCommand.maxPort, RelayConfig.portRange.upperBound)
    }

    /// Guards the drift that shipped: the lower bound must exclude privileged
    /// ports. A regression to 1 would make `validate` bless a port the admin API
    /// refuses — and the two assertions above would still pass, since they only
    /// prove the CLI agrees with `RelayConfig`, not that `RelayConfig` is right.
    func testSharedBoundExcludesPrivilegedPorts() {
        XCTAssertEqual(RelayConfig.portRange.lowerBound, 1024)
        XCTAssertEqual(RelayConfig.portRange.upperBound, 65535)
    }

    // MARK: - Range

    func testPortBelowServerMinimumIsReported() {
        // 80 parses and is within the old 1–65535 bound, but the admin API
        // rejects anything under 1024 on write.
        let result = validate(.int(80))
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(
            result.errors[0].contains("between 1024 and 65535"),
            "Expected the server's range in the message, got \(result.errors)"
        )
    }

    func testPortAboveMaximumIsReported() {
        XCTAssertEqual(validate(.int(70000)).errors.count, 1)
    }

    func testBoundariesAreAccepted() {
        XCTAssertTrue(validate(.int(1024)).errors.isEmpty)
        XCTAssertTrue(validate(.int(65535)).errors.isEmpty)
    }

    func testValidPortProducesNoErrors() {
        let result = validate(.int(9200))
        XCTAssertEqual(result.port, 9200)
        XCTAssertTrue(result.errors.isEmpty)
    }

    /// A port given as a numeric *string* (how it arrives over the admin API
    /// when the JSON carries a quoted value) still validates.
    func testNumericStringPortIsAccepted() {
        let result = validate(.string("9200"))
        XCTAssertEqual(result.port, 9200)
        XCTAssertTrue(result.errors.isEmpty)
    }

    // MARK: - Missing

    func testMissingPortIsNotAnError() {
        // Absent keys are the server's defaults, not a misconfiguration.
        let result = validate(nil)
        XCTAssertNil(result.port)
        XCTAssertTrue(result.errors.isEmpty)
    }

    // MARK: - Collision

    /// An out-of-range port is still returned so the caller can compare the two
    /// for equality — otherwise a config with both ports set to 80 would report
    /// the range problem, and only surface the collision after it was fixed.
    func testOutOfRangePortStillReturnsValueForCollisionCheck() {
        var errors: [String] = []
        let ws = ConfigValidateCommand.validatePort(.int(80), name: "wsPort", errors: &errors)
        let admin = ConfigValidateCommand.validatePort(.int(80), name: "adminPort", errors: &errors)

        // Non-nil is the point: a nil here would hide the collision behind the
        // range errors. (Asserting ws == admin on top of these would be
        // tautological — both are already pinned to 80.)
        XCTAssertEqual(ws, 80)
        XCTAssertEqual(admin, 80)
        XCTAssertEqual(errors.count, 2, "Both ports are out of range")
    }
}
