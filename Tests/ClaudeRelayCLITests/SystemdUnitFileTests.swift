#if os(Linux)
import XCTest
@testable import ClaudeRelayCLI

/// The unit `claude-relay load` writes, and the package template derived from it.
final class SystemdUnitFileTests: XCTestCase {

    private func directives(_ unit: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in unit.split(separator: "\n") where line.contains("=") && !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            out[parts[0]] = parts[1]
        }
        return out
    }

    func testUnitRunsTheGivenBinaryFromHomeAndRestartsOnFailure() {
        let unit = SystemdService.unitFile(serverBinary: "/usr/local/bin/claude-relay-server")
        let d = directives(unit)
        XCTAssertEqual(d["ExecStart"], "/usr/local/bin/claude-relay-server")
        XCTAssertEqual(d["WorkingDirectory"], "%h")
        XCTAssertEqual(d["Restart"], "always", "KeepAlive")
        XCTAssertEqual(d["RestartSec"], "5")
        XCTAssertEqual(d["WantedBy"], "default.target", "RunAtLoad: starts with the user's session")
        XCTAssertEqual(d["Type"], "simple")
    }

    func testUnitDoesNotPinALoginShellsPath() {
        let d = directives(SystemdService.unitFile(serverBinary: "/x"))
        XCTAssertEqual(d["Environment"], "PATH=/usr/local/bin:/usr/bin:/bin",
                       "sessions exec a login shell that rebuilds PATH; the service needs only the system dirs")
    }

    func testLoadWrittenUnitCarriesTheCLIMarkerAndThePackageTemplateDoesNot() {
        XCTAssertTrue(SystemdService.unitFile(serverBinary: "/x").contains(SystemdUnitDetector.cliMarker))
        XCTAssertFalse(SystemdService.unitFile(serverBinary: "/x", marker: nil).contains(SystemdUnitDetector.cliMarker))
    }

    func testUnitMentionsHowToReadLogsAndKeepRunningHeadless() {
        let unit = SystemdService.unitFile(serverBinary: "/x")
        XCTAssertTrue(unit.contains("journalctl --user -u claude-relay.service"))
        XCTAssertTrue(unit.contains("loginctl enable-linger"))
    }

    func testManagerDescriptionsAndJSONFollowTheOwner() {
        let packaged = SystemdService(detector: SystemdUnitDetector(
            packagedUnitExists: true, userUnitExists: false, userUnitWrittenByCLI: false))
        XCTAssertEqual(packaged.managerJSON, "systemd-package")
        XCTAssertTrue(packaged.managerDescription.contains("packaged"))

        let shadowing = SystemdService(detector: SystemdUnitDetector(
            packagedUnitExists: true, userUnitExists: true, userUnitWrittenByCLI: true))
        XCTAssertEqual(shadowing.managerJSON, "systemd-user")
        XCTAssertTrue(shadowing.managerDescription.contains("shadows"))

        let none = SystemdService(detector: SystemdUnitDetector(
            packagedUnitExists: false, userUnitExists: false, userUnitWrittenByCLI: false))
        XCTAssertEqual(none.managerJSON, "none")
    }

    func testSetupStartsAnInstalledUnitAndLoadsOtherwise() {
        let installed = SystemdService(detector: SystemdUnitDetector(
            packagedUnitExists: true, userUnitExists: false, userUnitWrittenByCLI: false))
        guard case .start = installed.setupStartPlan() else { return XCTFail("expected .start") }

        let fresh = SystemdService(detector: SystemdUnitDetector(
            packagedUnitExists: false, userUnitExists: false, userUnitWrittenByCLI: false))
        guard case .load = fresh.setupStartPlan() else { return XCTFail("expected .load") }
    }

    func testServerBinarySearchOrderIsSystemThenLocalThenHome() {
        let service = SystemdService(detector: SystemdUnitDetector(
            packagedUnitExists: false, userUnitExists: false, userUnitWrittenByCLI: false))
        XCTAssertEqual(service.serverBinaryCandidates.prefix(2),
                       ["/usr/bin/claude-relay-server", "/usr/local/bin/claude-relay-server"])
        XCTAssertTrue(service.serverBinaryCandidates[2].hasSuffix("/.claude-relay/bin/claude-relay-server"))
        XCTAssertEqual(service.serverBinaryFallback, "/usr/bin/claude-relay-server")
    }
}
#endif
