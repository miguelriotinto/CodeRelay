import XCTest
@testable import ClaudeRelayCLI

/// The Linux counterpart of `ServiceManagerDetectorTests`: which
/// `claude-relay.service` definition is in effect, and what each service verb
/// should do about it (`docs/linux-server-spec.md` AD-4). Pure on every
/// platform; the detector reads nothing but its injected inputs.
final class SystemdUnitDetectorTests: XCTestCase {

    private func detector(packaged: Bool, user: Bool, cli: Bool = true) -> SystemdUnitDetector {
        SystemdUnitDetector(packagedUnitExists: packaged, userUnitExists: user, userUnitWrittenByCLI: cli)
    }

    // MARK: - Owner

    func testOwnerIsNoneWithNoUnitFiles() {
        XCTAssertEqual(detector(packaged: false, user: false).owner, .none)
        XCTAssertNil(detector(packaged: false, user: false).activeUnitPath)
    }

    func testOwnerIsPackagedWhenOnlyThePackageUnitExists() {
        let d = detector(packaged: true, user: false)
        XCTAssertEqual(d.owner, .packaged)
        XCTAssertEqual(d.activeUnitPath, SystemdUnitDetector.packagedUnitPath)
        XCTAssertFalse(d.packagedUnitShadowed)
    }

    func testOwnerIsUserWhenOnlyTheUserUnitExists() {
        let d = detector(packaged: false, user: true)
        XCTAssertEqual(d.owner, .user)
        XCTAssertEqual(d.activeUnitPath, SystemdUnitDetector.userUnitPath)
    }

    /// systemd's unit search path: `~/.config/systemd/user` shadows
    /// `/usr/lib/systemd/user`. Both existing is not two managers — it is one
    /// active definition and one hidden file, which `status` should mention.
    func testUserUnitShadowsThePackagedOne() {
        let d = detector(packaged: true, user: true)
        XCTAssertEqual(d.owner, .user)
        XCTAssertTrue(d.packagedUnitShadowed)
    }

    // MARK: - Nudges

    func testNoNudgeForAnyVerbWhenAUnitIsInstalled() {
        for owner in [detector(packaged: true, user: false), detector(packaged: false, user: true)] {
            for verb in [ServiceVerb.start, .stop, .restart, .load, .unload] {
                XCTAssertNil(owner.nudge(for: verb), "\(owner.owner) \(verb)")
            }
        }
    }

    func testLoadIsNotNudgedOnAFreshMachine() {
        XCTAssertNil(detector(packaged: false, user: false).nudge(for: .load))
    }

    func testUnloadOnAFreshMachineSaysNothingToUnload() {
        XCTAssertEqual(detector(packaged: false, user: false).nudge(for: .unload),
                       "No service is installed — nothing to unload.")
    }

    func testStartOnFreshMachineNudgesTowardSetup() {
        for verb in [ServiceVerb.start, .stop, .restart] {
            let nudge = detector(packaged: false, user: false).nudge(for: verb)
            XCTAssertNotNil(nudge)
            XCTAssertTrue(nudge!.contains("claude-relay setup"), nudge!)
            XCTAssertTrue(nudge!.contains("nothing to \(verb.rawValue)"), nudge!)
        }
    }

    // MARK: - Paths

    func testUserUnitPathHonoursXDGConfigHome() {
        // The directory is derived from the environment at call time; assert the
        // shape rather than a specific home so the test is host-independent.
        XCTAssertTrue(SystemdUnitDetector.userUnitPath.hasSuffix("/systemd/user/claude-relay.service"))
        XCTAssertEqual(SystemdUnitDetector.packagedUnitPath, "/usr/lib/systemd/user/claude-relay.service")
    }
}
