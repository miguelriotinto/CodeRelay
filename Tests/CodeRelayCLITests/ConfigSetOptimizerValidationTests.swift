// Tests/CodeRelayCLITests/ConfigSetOptimizerValidationTests.swift
import XCTest
@testable import CodeRelayCLI
import CodeRelayKit

/// `config set` client-side fast path for the six promptOptimizer* keys. The
/// server (`AdminRoutes.applyConfigValue`) stays the authority; these only
/// give a round-trip-free error message for the common mistakes.
final class ConfigSetOptimizerValidationTests: XCTestCase {
    private func error(_ key: String, _ raw: String) -> String? {
        ConfigSetCommand.optimizerValidationError(key: key, value: ConfigValue.infer(from: raw))
    }

    func testProviderMustBeKnown() {
        XCTAssertNil(error("promptOptimizerProvider", "anthropic"))
        XCTAssertNil(error("promptOptimizerProvider", "bedrock"))
        XCTAssertEqual(error("promptOptimizerProvider", "openai"),
                       "promptOptimizerProvider must be one of: anthropic, bedrock")
    }

    func testRegionMustBeHostnameSafe() {
        XCTAssertNil(error("promptOptimizerRegion", "us-west-2"))
        XCTAssertEqual(error("promptOptimizerRegion", "us_west_2"), "promptOptimizerRegion must match [a-z0-9-]+")
    }

    func testBoolsMustInferAsBool() {
        XCTAssertNil(error("promptOptimizerEnabled", "true"))
        XCTAssertNil(error("promptOptimizerShareScreen", "false"))
        XCTAssertEqual(error("promptOptimizerEnabled", "yes"), "promptOptimizerEnabled must be true or false")
        XCTAssertEqual(error("promptOptimizerShareScreen", "1"), "promptOptimizerShareScreen must be true or false")
    }

    func testKeyPathMustExistUnlessEmpty() throws {
        XCTAssertNil(error("promptOptimizerKeyPath", ""))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertEqual(error("promptOptimizerKeyPath", missing), "promptOptimizerKeyPath path not found: \(missing)")
        let present = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "k".write(to: present, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: present) }
        XCTAssertNil(error("promptOptimizerKeyPath", present.path))
    }

    func testUnrelatedKeysAreNotJudged() {
        XCTAssertNil(error("promptOptimizerModel", "anything-goes"))
        XCTAssertNil(error("wsPort", "80"))
    }
}
