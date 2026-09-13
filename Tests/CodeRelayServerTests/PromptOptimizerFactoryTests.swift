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
}
