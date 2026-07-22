import XCTest
import Foundation
@testable import ClaudeRelayServer

final class PTYSessionCwdTests: XCTestCase {
    /// Verifies the cwd accessor returns the child shell's directory once the
    /// login shell is up. Uses output as the readiness signal rather than a
    /// fixed sleep, so it is robust to profile-script startup latency.
    func testCurrentWorkingDirectoryReadsShellCwd() async throws {
        let session = try PTYSession(sessionId: UUID(), cols: 80, rows: 24, scrollbackSize: 8192)
        let gotOutput = expectation(description: "shell produced output")
        gotOutput.assertForOverFulfill = false
        await session.setOutputHandler { _ in gotOutput.fulfill() }
        await session.startReading()
        defer { Task { await session.terminate() } }

        // Nudge the shell to print, proving it is alive and executing commands.
        await session.write("cd /tmp && pwd\n".data(using: .utf8)!)
        await fulfillment(of: [gotOutput], timeout: 5.0)
        // Give the cd a beat to settle after the prompt echo.
        try await Task.sleep(for: .milliseconds(400))

        let cwd = await session.currentWorkingDirectory()
        XCTAssertNotNil(cwd, "cwd should be readable while the shell child is alive")
        if let cwd { XCTAssertTrue(cwd == "/tmp" || cwd == "/private/tmp", "got \(cwd)") }
    }
}
