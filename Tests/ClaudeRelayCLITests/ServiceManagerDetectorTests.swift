import XCTest
@testable import ClaudeRelayCLI

final class ServiceManagerDetectorTests: XCTestCase {

    private func detector(brew: Bool, agent: Bool, binary: String = "/opt/homebrew/bin/claude-relay")
        -> ServiceManagerDetector {
        ServiceManagerDetector(homebrewPlistExists: brew, launchAgentPlistExists: agent, binaryPath: binary)
    }

    // MARK: - Owner resolution

    func testOwnerIsHomebrewWhenOnlyBrewPlistPresent() {
        XCTAssertEqual(detector(brew: true, agent: false).owner, .homebrew)
    }

    func testOwnerIsLaunchAgentWhenOnlyCLIPlistPresent() {
        XCTAssertEqual(detector(brew: false, agent: true).owner, .launchAgent)
    }

    func testOwnerIsBothWhenTwoManagersPresent() {
        XCTAssertEqual(detector(brew: true, agent: true).owner, .both)
    }

    func testOwnerIsNoneWhenNoPlistPresent() {
        XCTAssertEqual(detector(brew: false, agent: false).owner, .none)
    }

    // MARK: - Installer hint

    func testInstalledViaHomebrewForAppleSiliconPrefix() {
        XCTAssertTrue(detector(brew: false, agent: false, binary: "/opt/homebrew/bin/claude-relay").installedViaHomebrew)
    }

    func testInstalledViaHomebrewForIntelPrefix() {
        XCTAssertTrue(detector(brew: false, agent: false, binary: "/usr/local/bin/claude-relay").installedViaHomebrew)
    }

    func testLocalBuildIsNotHomebrew() {
        XCTAssertFalse(detector(brew: false, agent: false, binary: "/Users/me/CodeRelay/.build/debug/claude-relay").installedViaHomebrew)
    }

    // MARK: - Correct command per owner

    func testHomebrewOwnerYieldsBrewCommands() {
        let d = detector(brew: true, agent: false)
        XCTAssertEqual(d.startCommand(), "brew services start clauderelay")
        XCTAssertEqual(d.stopCommand(), "brew services stop clauderelay")
        XCTAssertEqual(d.restartCommand(), "brew services restart clauderelay")
    }

    func testLaunchAgentOwnerYieldsCLICommands() {
        let d = detector(brew: false, agent: true)
        XCTAssertEqual(d.startCommand(), "claude-relay start")
        XCTAssertEqual(d.stopCommand(), "claude-relay stop")
        XCTAssertEqual(d.restartCommand(), "claude-relay restart")
    }

    // MARK: - Nudges

    func testStartStopRestartAreNudgedUnderHomebrew() {
        let d = detector(brew: true, agent: false)
        for verb in [ServiceVerb.start, .stop, .restart] {
            let nudge = d.nudge(for: verb)
            XCTAssertNotNil(nudge, "\(verb) should be nudged under Homebrew")
            XCTAssertTrue(nudge!.contains("brew services"), "nudge should name the right tool: \(nudge!)")
        }
    }

    func testNoNudgeUnderLaunchAgentOwnership() {
        let d = detector(brew: false, agent: true)
        for verb in [ServiceVerb.start, .stop, .restart, .load, .unload] {
            XCTAssertNil(d.nudge(for: verb), "\(verb) is this manager's own command")
        }
    }

    func testLoadIsNudgedUnderHomebrewToAvoidASecondManager() {
        let nudge = detector(brew: true, agent: false).nudge(for: .load)
        XCTAssertNotNil(nudge)
        XCTAssertTrue(nudge!.contains("brew services start clauderelay"), nudge!)
    }

    func testLoadIsNotNudgedOnAFreshMachine() {
        XCTAssertNil(detector(brew: false, agent: false).nudge(for: .load))
    }

    func testBothManagersProduceAWarningForEveryVerb() {
        let d = detector(brew: true, agent: true)
        for verb in [ServiceVerb.start, .stop, .restart, .load, .unload] {
            let nudge = d.nudge(for: verb)
            XCTAssertNotNil(nudge, "\(verb) should warn when two managers exist")
            XCTAssertTrue(nudge!.lowercased().contains("two"), nudge!)
        }
    }

    func testStartOnFreshMachineNudgesTowardSetup() {
        let nudge = detector(brew: false, agent: false, binary: "/Users/me/CodeRelay/.build/debug/claude-relay").nudge(for: .start)
        XCTAssertNotNil(nudge)
        XCTAssertTrue(nudge!.contains("claude-relay setup"), nudge!)
    }
}
