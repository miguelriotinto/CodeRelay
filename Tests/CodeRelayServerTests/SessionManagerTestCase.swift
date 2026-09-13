import XCTest
import Foundation
@testable import CodeRelayServer
@testable import CodeRelayKit

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
    private var clipboardHandler: (@Sendable (String) -> Void)?
    func setClipboardHandler(_ handler: @escaping @Sendable (String) -> Void) { clipboardHandler = handler }
    /// Test hook: simulate the terminal emitting an OSC 52 clipboard write.
    func emitClipboard(_ text: String) { clipboardHandler?(text) }
    func clearOutputHandler() {
        outputHandler = nil
        clipboardHandler = nil
        clearOutputHandlerCallCount += 1
    }
    private var writes: [Data] = []
    private var mockPromptContext = PromptContext(
        draft: "", agentId: nil, agentDisplayName: nil, workingDirectory: nil,
        screenLines: [], bracketedPaste: false, keyboardFlagsRawValue: 0)

    func write(_ data: Data) { writes.append(data) }
    func recordedWrites() -> [Data] { writes }
    /// Every draft adopted through `replaceDraft`, in order. Its bytes land in
    /// `writes` exactly as a plain `write` would, so write assertions do not care
    /// which path produced them.
    private var adoptedDrafts: [String] = []
    /// Mirrors `PTYSession.replaceDraft`'s contract against `mockPromptContext`:
    /// `draftKnown == false` stands in for a lost mirror, and `.exactly` compares
    /// the tracked agent. A refusal writes nothing and adopts nothing.
    @discardableResult
    func replaceDraft(with text: String, forAgent expectation: AgentExpectation) -> Bool {
        guard !terminated, mockPromptContext.draftKnown else { return false }
        if case .exactly(let expected) = expectation, expected != mockPromptContext.agentId { return false }
        let bytes = DraftReplacer.bytes(replacing: mockPromptContext.draft, with: text,
                                        bracketedPaste: mockPromptContext.bracketedPaste,
                                        keyboardFlags: mockPromptContext.keyboardFlags)
        write(bytes)
        adoptedDrafts.append(DraftReplacer.effectiveText(text, bracketedPaste: mockPromptContext.bracketedPaste))
        return true
    }
    func recordedAdoptedDrafts() -> [String] { adoptedDrafts }
    func setMockPromptContext(_ context: PromptContext) { mockPromptContext = context }
    /// Test hook: install `context` only once `promptContext` has been read
    /// `afterReads` times, so a test can change what the actor sees *after* a
    /// handler's mid-flight re-check has already run.
    func setMockPromptContext(_ context: PromptContext, afterReads: Int) {
        deferredContext = (afterReads, context)
    }
    private var promptContextReads = 0
    private var deferredContext: (afterReads: Int, context: PromptContext)?
    func promptContext(includeScreen: Bool) -> PromptContext {
        promptContextReads += 1
        defer {
            if let deferred = deferredContext, promptContextReads >= deferred.afterReads {
                mockPromptContext = deferred.context
                deferredContext = nil
            }
        }
        guard includeScreen else {
            return PromptContext(
                draft: mockPromptContext.draft, agentId: mockPromptContext.agentId,
                agentDisplayName: mockPromptContext.agentDisplayName,
                workingDirectory: mockPromptContext.workingDirectory, screenLines: [],
                bracketedPaste: mockPromptContext.bracketedPaste,
                keyboardFlagsRawValue: mockPromptContext.keyboardFlagsRawValue,
                draftKnown: mockPromptContext.draftKnown)
        }
        return mockPromptContext
    }
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
    /// Records every cadence change so tests can assert that attach/resume
    /// restore the fast poll and detach slows it back down.
    private(set) var pollCadences: [TimeInterval] = []
    var lastPollCadence: TimeInterval? { pollCadences.last }
    func setPollCadence(_ seconds: TimeInterval) async {
        if let gate = pollCadenceGate {
            // Suspends the *caller* — i.e. SessionManager — inside its
            // `await pty.setPollCadence(...)`, holding it at that exact
            // suspension point so a test can drive a reentrant call into
            // SessionManager and observe what state it sees. See
            // `testDetachTimerIsInstalledBeforeCadenceSuspension`.
            await gate.wait()
        }
        pollCadences.append(seconds)
        if let hook = onPollCadenceWrite {
            // Same idea as the gate, but re-armable: the caller stays suspended
            // here for as many writes as the test wants, so it can commit a
            // fresh transition on each pass instead of only once. Both actors
            // are reentrant at their awaits, so a hook that calls back into
            // `SessionManager` (and from there into this mock) cannot deadlock.
            await hook(pollCadences.count)
        }
    }

    /// Set to hold `setPollCadence` open until the test releases it.
    private var pollCadenceGate: AsyncGate?
    func installPollCadenceGate(_ gate: AsyncGate) { pollCadenceGate = gate }
    func removePollCadenceGate() { pollCadenceGate = nil }

    /// Invoked after each cadence write with that write's 1-based index. Lets a
    /// test commit a lifecycle transition while `SessionManager` is suspended in
    /// the write, forcing its sync loop to take another repair pass.
    private var onPollCadenceWrite: (@Sendable (Int) async -> Void)?
    func setPollCadenceWriteHook(_ hook: @escaping @Sendable (Int) async -> Void) {
        onPollCadenceWrite = hook
    }
    func removePollCadenceWriteHook() { onPollCadenceWrite = nil }
    /// Records the last hook state applied, so tests can assert that
    /// `SessionManager.reportHookState` forwarded to the PTY.
    private(set) var lastHookState: AgentDetectedState?
    func applyHookState(_ hookState: AgentDetectedState) { lastHookState = hookState }

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

// MARK: - AsyncGate

/// A one-shot gate: `wait()` suspends until someone calls `open()`. Lets a test
/// pin a production actor at a chosen suspension point instead of racing it with
/// sleeps, so reentrancy assertions are deterministic rather than probabilistic.
///
/// `open()` before any `wait()` is safe — the gate latches, so a later `wait()`
/// returns immediately rather than parking forever.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0

    func wait() async {
        if isOpen { return }
        // Incremented before suspending, and `withCheckedContinuation`'s closure
        // runs synchronously on this actor, so once `hasArrived` is true the
        // caller is genuinely parked with its continuation registered.
        arrivals += 1
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Whether anyone is parked in `wait()`. A latch, not a transient: it stays
    /// true until `open()`, which is what makes polling for it sound.
    var hasArrived: Bool { arrivals > 0 }

    func open() {
        isOpen = true
        for continuation in waiters { continuation.resume() }
        waiters.removeAll()
    }
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
