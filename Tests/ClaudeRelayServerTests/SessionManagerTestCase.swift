import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

// MARK: - MockPTYSession

actor MockPTYSession: PTYSessionProtocol {
    let sessionId: UUID
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var exitHandler: (@Sendable () -> Void)?
    private var terminated = false
    private var activityHandler: (@Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void)?
    private(set) var clearOutputHandlerCallCount = 0
    private(set) var forceRepaintCallCount = 0
    /// Whether the live output handler was already wired when `forceRepaint()`
    /// fired — the repaint's redraw bytes must reach the client, not just the
    /// ring buffer, so ordering matters.
    private(set) var forceRepaintSawOutputHandler = false
    private var bufferContents = Data()

    init(sessionId: UUID, cols: UInt16, rows: UInt16, scrollbackSize: Int) {
        self.sessionId = sessionId
    }

    func startReading() {}
    func setOutputHandler(_ handler: @escaping @Sendable (Data) -> Void) { outputHandler = handler }
    func setExitHandler(_ handler: @escaping @Sendable () -> Void) { exitHandler = handler }
    func clearOutputHandler() {
        outputHandler = nil
        clearOutputHandlerCallCount += 1
    }
    func write(_ data: Data) {}
    func resize(cols: UInt16, rows: UInt16) {}
    /// Test hook: settable cwd returned by `currentWorkingDirectory()`.
    var mockCwd: String?
    func setMockCwd(_ path: String?) { mockCwd = path }
    func currentWorkingDirectory() -> String? { mockCwd }
    private var workingDirHandler: (@Sendable (String) -> Void)?
    func setWorkingDirHandler(_ handler: @escaping @Sendable (String) -> Void) { workingDirHandler = handler }
    /// Test hook: simulate the foreground poll firing the cwd handler.
    func emitWorkingDir(_ cwd: String) { workingDirHandler?(cwd) }
    func forceRepaint() {
        forceRepaintCallCount += 1
        forceRepaintSawOutputHandler = outputHandler != nil
    }
    func readBuffer() -> Data { bufferContents }
    func terminate() { terminated = true }
    func getActivityState() -> ActivityState { .active }
    func getActiveAgent() -> CodingAgent? { nil }
    func getAgentState() -> AgentDetectedState? { nil }
    func getTitle() -> String? { nil }
    func setActivityHandler(
        _ handler: @escaping @Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void
    ) {
        activityHandler = handler
    }
    func recordInput() {}
    func setPollCadence(_ seconds: TimeInterval) {}

    /// Test hook: seed the ring buffer with data for replay tests.
    func writeToBuffer(_ data: Data) {
        bufferContents.append(data)
    }

    /// Test hook: drives the dispatch-source equivalent so tests can verify
    /// the currently-installed output callback (proxy for "which device is
    /// wired up right now").
    func deliverOutput(_ data: Data) {
        outputHandler?(data)
    }

    /// Test hook: whether any output callback is currently installed.
    var hasOutputHandler: Bool { outputHandler != nil }
}

// MARK: - Shared base

/// Shared scaffolding for SessionManager-focused test suites. Subclasses focus on
/// lifecycle, observers, or ownership without each re-declaring a temp dir,
/// token store, and mock PTY factory.
class SessionManagerTestCase: XCTestCase {

    var tempDir: URL!
    var tokenStore: TokenStore!
    var config: RelayConfig!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tokenStore = TokenStore(directory: tempDir)
        config = RelayConfig(detachTimeout: 5, scrollbackSize: 4096)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func createTestToken(label: String = "test") async throws -> (plaintext: String, info: TokenInfo) {
        try await tokenStore.create(label: label)
    }

    func makeManager(config: RelayConfig? = nil) -> SessionManager {
        SessionManager(config: config ?? self.config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })
    }
}
