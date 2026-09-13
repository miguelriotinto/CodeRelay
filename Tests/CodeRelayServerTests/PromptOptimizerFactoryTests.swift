import XCTest
import Foundation
import NIOPosix
import AsyncHTTPClient
@testable import CodeRelayKit
@testable import CodeRelayServer

final class PromptOptimizerFactoryTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var tempDir: URL!

    override func setUp() async throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OptimizerFactory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await group.shutdownGracefully()
    }

    private func writeKey(_ contents: String, mode: Int16 = 0o600) throws -> String {
        let url = tempDir.appendingPathComponent("key")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
        return url.path
    }

    private func make(_ config: RelayConfig) async throws -> (any PromptOptimizing)? {
        var http: HTTPClient?
        let optimizer = PromptOptimizerFactory.make(config: config, group: group, out: &http)
        if let http { try await http.shutdown() }
        return optimizer
    }

    func testDisabledYieldsNilEvenWithAKey() async throws {
        var config = RelayConfig.default
        config.promptOptimizerEnabled = false
        config.promptOptimizerKeyPath = try writeKey("sk-ant-test")
        let result = try await make(config)
        XCTAssertNil(result)
    }

    func testEnabledWithoutKeyPathYieldsNil() async throws {
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        let result = try await make(config)
        XCTAssertNil(result)
    }

    func testEnabledWithMissingKeyFileYieldsNil() async throws {
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = tempDir.appendingPathComponent("nope").path
        let result = try await make(config)
        XCTAssertNil(result)
    }

    func testEnabledWithEmptyKeyFileYieldsNil() async throws {
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = try writeKey("   \n")
        let result = try await make(config)
        XCTAssertNil(result)
    }

    func testEnabledWithBadProviderYieldsNil() async throws {
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = try writeKey("sk-ant-test")
        config.promptOptimizerProvider = "openai"
        let result = try await make(config)
        XCTAssertNil(result)
    }

    func testEnabledWithKeyYieldsOptimizerHonouringShareScreen() async throws {
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = try writeKey("sk-ant-test\n")
        config.promptOptimizerShareScreen = false
        let optimizer = try await make(config)
        XCTAssertNotNil(optimizer)
        XCTAssertEqual(optimizer?.sharesScreen, false)
    }

    func testBedrockProviderResolvesWithARegion() async throws {
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = try writeKey("bedrock-api-key")
        config.promptOptimizerProvider = "bedrock"
        config.promptOptimizerRegion = "eu-west-1"
        let result = try await make(config)
        XCTAssertNotNil(result)
    }

    func testReadKeyTrimsWhitespaceAndLoadsLooseMode() throws {
        let path = try writeKey("  sk-ant-loose \n", mode: 0o644)
        XCTAssertEqual(try PromptOptimizerFactory.readKey(atPath: path), "sk-ant-loose")
    }

    // MARK: - Log Coverage Tests
    //
    // `LogStore.recent(count:)` returns the LAST `count` entries, so a before/after
    // comparison can never be positional: once the process has logged more than
    // `count` lines, `before.count == after.count` is trivially true and
    // `after.dropFirst(before.count)` reads a slice that has nothing to do with
    // the new lines. These tests compare *filtered counts* over a window large
    // enough to contain both snapshots, and — where the message carries the key
    // path — narrow the filter to this test run's unique temp directory name.

    /// Wide enough to hold both snapshots of a single test's logging.
    private static let logWindow = 2_000

    private func optimizerErrorCount(mentioning needle: String? = nil) -> Int {
        RelayLogger.store.recent(count: Self.logWindow).filter { line in
            guard line.contains("[ERROR]"), line.contains("[optimizer]") else { return false }
            guard let needle else { return true }
            return line.contains(needle)
        }.count
    }

    private func optimizerLines(mentioning needle: String) -> [String] {
        RelayLogger.store.recent(count: Self.logWindow).filter {
            $0.contains("[optimizer]") && $0.contains(needle)
        }
    }

    func testDisabledConfigLogsNothing() async throws {
        // Unique to this test run, so no other suite's line can be miscounted.
        let marker = tempDir.lastPathComponent
        let beforeErrors = optimizerErrorCount()
        let beforeMarked = optimizerLines(mentioning: marker).count
        var config = RelayConfig.default
        config.promptOptimizerEnabled = false
        config.promptOptimizerKeyPath = try writeKey("sk-ant-test")
        let result = try await make(config)
        XCTAssertNil(result)
        XCTAssertEqual(optimizerErrorCount() - beforeErrors, 0, "Disabled config should log no error")
        XCTAssertEqual(optimizerLines(mentioning: marker).count - beforeMarked, 0,
                       "Disabled config should log nothing at all")
    }

    func testUnusableConfigLogsExactlyOneError() async throws {
        let marker = tempDir.lastPathComponent
        let before = optimizerErrorCount(mentioning: marker)
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = tempDir.appendingPathComponent("missing").path
        let result = try await make(config)
        XCTAssertNil(result)
        XCTAssertEqual(optimizerErrorCount(mentioning: marker) - before, 1,
                       "Unusable config should log exactly one error")
    }

    func testInvalidRegionLogsOneError() async throws {
        // The region error carries no path, so this one counts optimizer errors.
        let before = optimizerErrorCount()
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = try writeKey("bedrock-key")
        config.promptOptimizerProvider = "bedrock"
        config.promptOptimizerRegion = "INVALID REGION"
        let result = try await make(config)
        XCTAssertNil(result)
        XCTAssertEqual(optimizerErrorCount() - before, 1, "Invalid region should log exactly one error")
    }

    func testKeyWithInteriorNewlineLogsOneErrorWithoutKey() async throws {
        let keyWithNewline = "sk-ant\ntest123"
        let path = try writeKey(keyWithNewline, mode: 0o600)
        let marker = tempDir.lastPathComponent
        let before = optimizerErrorCount(mentioning: marker)
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = path
        let result = try await make(config)
        XCTAssertNil(result)
        XCTAssertEqual(optimizerErrorCount(mentioning: marker) - before, 1,
                       "Invalid key should log exactly one error")
        // Ensure the key material is not in the log.
        for log in optimizerLines(mentioning: marker) {
            XCTAssertFalse(log.contains("sk-ant"), "Log should not contain key material")
            XCTAssertFalse(log.contains("test123"), "Log should not contain key material")
        }
    }

    func testDirectoryAtKeyPathLogsOneError() async throws {
        let dirPath = tempDir.appendingPathComponent("keydir").path
        try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        let marker = tempDir.lastPathComponent
        let before = optimizerErrorCount(mentioning: marker)
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = dirPath
        let result = try await make(config)
        XCTAssertNil(result)
        XCTAssertEqual(optimizerErrorCount(mentioning: marker) - before, 1,
                       "Directory at keyPath should log exactly one error")
    }

    func testDefaultModelsResolveCorrectly() throws {
        XCTAssertEqual(MessagesEndpoint.anthropic.defaultModel, "claude-sonnet-5")
        XCTAssertEqual(MessagesEndpoint.bedrock(region: "eu-west-1").defaultModel, "anthropic.claude-sonnet-5")
    }
}
