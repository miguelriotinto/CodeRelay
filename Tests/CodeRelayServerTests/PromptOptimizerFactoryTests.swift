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

    func testDisabledConfigLogsNothing() async throws {
        let before = RelayLogger.store.recent(count: 100)
        var config = RelayConfig.default
        config.promptOptimizerEnabled = false
        config.promptOptimizerKeyPath = try writeKey("sk-ant-test")
        let result = try await make(config)
        let after = RelayLogger.store.recent(count: 100)
        XCTAssertNil(result)
        XCTAssertEqual(before.count, after.count, "Disabled config should log nothing")
    }

    func testUnusableConfigLogsExactlyOneError() async throws {
        let before = RelayLogger.store.recent(count: 100)
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = tempDir.appendingPathComponent("missing").path
        let result = try await make(config)
        let after = RelayLogger.store.recent(count: 100)
        XCTAssertNil(result)
        let newLogs = after.dropFirst(before.count)
        let errorLogs = newLogs.filter { $0.contains("[ERROR]") && $0.contains("[optimizer]") }
        XCTAssertEqual(errorLogs.count, 1, "Unusable config should log exactly one error")
    }

    func testInvalidRegionLogsOneError() async throws {
        let before = RelayLogger.store.recent(count: 100)
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = try writeKey("bedrock-key")
        config.promptOptimizerProvider = "bedrock"
        config.promptOptimizerRegion = "INVALID REGION"
        let result = try await make(config)
        let after = RelayLogger.store.recent(count: 100)
        XCTAssertNil(result)
        let newLogs = after.dropFirst(before.count)
        let errorLogs = newLogs.filter { $0.contains("[ERROR]") && $0.contains("[optimizer]") }
        XCTAssertEqual(errorLogs.count, 1, "Invalid region should log exactly one error")
    }

    func testKeyWithInteriorNewlineLogsOneErrorWithoutKey() async throws {
        let keyWithNewline = "sk-ant\ntest123"
        let path = try writeKey(keyWithNewline, mode: 0o600)
        let before = RelayLogger.store.recent(count: 100)
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = path
        let result = try await make(config)
        let after = RelayLogger.store.recent(count: 100)
        XCTAssertNil(result)
        let newLogs = after.dropFirst(before.count)
        let errorLogs = newLogs.filter { $0.contains("[ERROR]") && $0.contains("[optimizer]") }
        XCTAssertEqual(errorLogs.count, 1, "Invalid key should log exactly one error")
        // Ensure the key material is not in the log.
        for log in errorLogs {
            XCTAssertFalse(log.contains("sk-ant"), "Log should not contain key material")
            XCTAssertFalse(log.contains("test123"), "Log should not contain key material")
        }
    }

    func testDirectoryAtKeyPathLogsOneError() async throws {
        let dirPath = tempDir.appendingPathComponent("keydir").path
        try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        let before = RelayLogger.store.recent(count: 100)
        var config = RelayConfig.default
        config.promptOptimizerEnabled = true
        config.promptOptimizerKeyPath = dirPath
        let result = try await make(config)
        let after = RelayLogger.store.recent(count: 100)
        XCTAssertNil(result)
        let newLogs = after.dropFirst(before.count)
        let errorLogs = newLogs.filter { $0.contains("[ERROR]") && $0.contains("[optimizer]") }
        XCTAssertEqual(errorLogs.count, 1, "Directory at keyPath should log exactly one error")
    }

    func testDefaultModelsResolveCorrectly() throws {
        XCTAssertEqual(MessagesEndpoint.anthropic.defaultModel, "claude-sonnet-5")
        XCTAssertEqual(MessagesEndpoint.bedrock(region: "eu-west-1").defaultModel, "anthropic.claude-sonnet-5")
    }
}
