import XCTest
@testable import CodeRelayCLI

/// `serverName` is read once at startup by ServerIdentityStore, so `config set`
/// must tell the operator a restart is needed — exactly like promptOptimizer*.
final class ConfigSetServerNameTests: XCTestCase {
    func testServerNameGetsTheRestartHint() {
        XCTAssertEqual(ConfigSetCommand.restartHint(forKey: "serverName"),
                       "Note: serverName is read at startup — run 'claude-relay restart' to apply.")
    }

    func testOtherKeysAreUnchanged() {
        XCTAssertNil(ConfigSetCommand.restartHint(forKey: "wsPort"))
        XCTAssertEqual(ConfigSetCommand.restartHint(forKey: "promptOptimizerEnabled"),
                       "Note: optimizer settings are read at startup — run 'claude-relay restart' to apply.")
    }

    func testServerNameIsAnAcceptedKey() {
        XCTAssertTrue(ConfigSetCommand.validKeys.contains("serverName"))
    }
}
