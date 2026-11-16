import XCTest
@testable import CodeRelayCLI

/// `serverName` is read once at startup by ServerIdentityStore, so `config set`
/// must tell the operator a restart is needed.
final class ConfigSetServerNameTests: XCTestCase {
    func testServerNameGetsTheRestartHint() {
        XCTAssertEqual(ConfigSetCommand.restartHint(forKey: "serverName"),
                       "Note: serverName is read at startup — run 'claude-relay restart' to apply.")
    }

    func testOtherKeysAreUnchanged() {
        XCTAssertNil(ConfigSetCommand.restartHint(forKey: "wsPort"))
        XCTAssertNil(ConfigSetCommand.restartHint(forKey: "promptOptimizerEnabled"))
        XCTAssertFalse(ConfigSetCommand.validKeys.contains("promptOptimizerEnabled"))
    }

    func testServerNameIsShippedAsTheRawStringNotInferred() {
        // `config set serverName 0042` must store "0042", not 42; `true` must
        // store the word, not a boolean. Inference is for the typed keys only.
        XCTAssertEqual(ConfigSetCommand.wireValue(forKey: "serverName", raw: "0042"), .string("0042"))
        XCTAssertEqual(ConfigSetCommand.wireValue(forKey: "serverName", raw: "true"), .string("true"))
        XCTAssertEqual(ConfigSetCommand.wireValue(forKey: "wsPort", raw: "9200"), .int(9200))
        XCTAssertEqual(ConfigSetCommand.wireValue(forKey: "bindAll", raw: "true"), .bool(true))
    }

    func testServerNameIsAnAcceptedKey() {
        XCTAssertTrue(ConfigSetCommand.validKeys.contains("serverName"))
    }
}
