import Combine
import XCTest
@testable import ClaudeRelayClient

@MainActor
final class TerminalViewModelTests: XCTestCase {

    private func makeVM(
        normal: Duration = .milliseconds(80),
        agentActive: Duration = .milliseconds(160)
    ) -> TerminalViewModel {
        let connection = RelayConnection()
        return TerminalViewModel(
            sessionId: UUID(),
            connection: connection,
            promptThresholds: InputPromptThresholds(
                normal: normal,
                agentActive: agentActive
            )
        )
    }

    /// Polls `condition()` every 10 ms up to `timeout`, returning once it's true
    /// or the timeout expires. Lets timing-sensitive tests finish on the fast
    /// path and tolerate scheduler jitter without inflating the test runtime.
    private func waitFor(
        timeout: Duration = .milliseconds(500),
        _ condition: () -> Bool
    ) async throws {
        let start = Date()
        let timeoutSeconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        while !condition() {
            if Date().timeIntervalSince(start) >= timeoutSeconds {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testBuffersOutputBeforeTerminalReady() {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }

        vm.receiveOutput(Data([0x41]))
        vm.receiveOutput(Data([0x42]))

        XCTAssertTrue(received.isEmpty, "Output should be buffered until terminalReady()")
    }

    func testTerminalReadyFlushesBuffer() {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }

        vm.receiveOutput(Data([0x41]))
        vm.receiveOutput(Data([0x42]))
        vm.terminalReady()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0], Data([0x41, 0x42]))
    }

    func testOutputForwardedAfterReady() {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        vm.receiveOutput(Data([0x43]))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0], Data([0x43]))
    }

    func testTerminalReadyIsIdempotent() {
        let vm = makeVM()
        var count = 0
        vm.onTerminalOutput = { _ in count += 1 }

        vm.receiveOutput(Data([0x41]))
        vm.terminalReady()
        vm.terminalReady()

        XCTAssertEqual(count, 1, "Second terminalReady should be a no-op")
    }

    func testPrepareForSwitchClearsState() {
        let vm = makeVM()
        vm.onTerminalOutput = { _ in }
        vm.onTitleChanged = { _ in }
        vm.terminalReady()
        vm.receiveOutput(Data([0x41]))

        vm.prepareForSwitch()

        XCTAssertNil(vm.onTerminalOutput)
        XCTAssertNil(vm.onTitleChanged)
        XCTAssertNil(vm.onAwaitingInputChanged)
    }

    func testPrepareForReplayThenTerminalReadySendsRIS() {
        let vm = makeVM()
        vm.onTerminalOutput = { _ in }
        vm.terminalReady()
        vm.receiveOutput(Data([0x41]))

        vm.prepareForReplay()

        XCTAssertNil(vm.onTerminalOutput)
        XCTAssertNil(vm.onTitleChanged)

        // Mirror coordinator flow: beginReplay → wire handler → terminalReady.
        // terminalReady detects isReplaying and immediately feeds RIS.
        vm.beginReplay()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0], Data([0x1B, 0x63]))
    }

    /// The macOS session-switch garble: the server's `replay_complete` arrives
    /// (endReplay) BEFORE the terminal view lays out (terminalReady), because
    /// `updateNSView` is scheduled only after the `activeSessionId` publish. The
    /// RIS clear that wipes the reused view's stale glyphs must still be emitted
    /// — and must precede the flushed scrollback — even in this order.
    func testReplayCompletesBeforeLayoutStillClearsThenFlushes() {
        let vm = makeVM()

        // Coordinator flow for a cache-hit switch: prepareForReplay → beginReplay
        // → wire handler → resumeSession streams scrollback → replay_complete.
        vm.prepareForReplay()
        vm.beginReplay()

        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        var replayFlushCount = 0
        vm.onReplayFlushed = { replayFlushCount += 1 }

        // Scrollback frames arrive while the view is still laying out.
        vm.receiveOutput(Data([0x41, 0x42]))    // "AB"

        // replay_complete fires BEFORE terminalReady() (the macOS race). Nothing
        // should be emitted yet — the view isn't laid out.
        vm.endReplay()
        XCTAssertTrue(received.isEmpty, "Must not flush before the view is laid out")
        XCTAssertEqual(replayFlushCount, 0, "Redraw must wait until replay bytes reach the terminal")

        // Now the view lays out. Expect a single blob: RIS clear + buffered
        // scrollback, in that order, so old glyphs are wiped before repaint.
        vm.terminalReady()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0], Data([0x1B, 0x63, 0x41, 0x42]),
            "RIS (ESC c) must precede the flushed scrollback in one pass")
        XCTAssertEqual(replayFlushCount, 1, "The terminal whose replay flushed must be redrawn once")
    }

    /// The normal (iOS) ordering: the view lays out while still replaying, so
    /// RIS fires immediately from terminalReady(); the buffered scrollback then
    /// flushes on endReplay(). Guards against a double-RIS regression.
    func testReplayLayoutBeforeCompleteClearsOnceThenFlushes() {
        let vm = makeVM()
        vm.prepareForReplay()
        vm.beginReplay()

        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        var replayFlushCount = 0
        vm.onReplayFlushed = { replayFlushCount += 1 }

        // View lays out first → RIS emitted immediately.
        vm.terminalReady()
        XCTAssertEqual(received, [Data([0x1B, 0x63])])

        // Scrollback arrives, then replay_complete flushes it (no second RIS).
        vm.receiveOutput(Data([0x41, 0x42]))
        vm.endReplay()
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[1], Data([0x41, 0x42]))
        XCTAssertEqual(replayFlushCount, 1, "Replay completion must redraw the terminal that received the bytes")
    }

    func testResetForReplaySendsRIS() {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        vm.resetForReplay()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0], Data([0x1B, 0x63]))
    }

    // MARK: - Server reload (session-name tap)

    /// The whole point of the tap: the server's copy REPLACES the local one.
    /// The replay must therefore arrive as a single RIS-prefixed blob — RIS
    /// alone would blank the pane for the round trip, and no RIS at all would
    /// append the fresh copy below the stale one.
    func testServerReloadClearsScreenAndRendersReplayAsOneBlob() {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        vm.beginServerReload()
        vm.receiveOutput(Data([0x41]))
        vm.receiveOutput(Data([0x42]))
        XCTAssertTrue(received.isEmpty, "Replay must be held, not painted incrementally")

        vm.endReplay()

        XCTAssertEqual(received.count, 1, "Clear + fresh copy must land in one display pass")
        XCTAssertEqual(received[0], Data([0x1B, 0x63, 0x41, 0x42]))
    }

    /// Output that arrived before the tap describes the screen being thrown
    /// away, so it must not be replayed after the clear.
    func testServerReloadDropsOutputBufferedBeforeTheTap() {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        // No terminalReady() yet → this chunk is sitting in the pending buffer.
        vm.receiveOutput(Data([0x41]))

        vm.beginServerReload()
        vm.terminalReady()          // wires up; emits the clear itself while replaying
        vm.receiveOutput(Data([0x42]))
        vm.endReplay()

        XCTAssertEqual(received, [Data([0x1B, 0x63]), Data([0x42])],
                       "Stale pre-tap bytes must not survive the reload")
    }

    /// Repaint flicker: the server width-wiggles the PTY after every replay,
    /// emitting two frames ~150 ms apart (narrow, then full width). Those land
    /// AFTER `replay_complete`, so the reload arms coalescing on the way out and
    /// both frames arrive in ONE `onTerminalOutput` call — SwiftTerm then renders
    /// only the final frame instead of flashing the narrow one.
    func testServerReloadCoalescesPostReplayRepaintBurst() async throws {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        vm.beginServerReload()
        vm.endReplay()
        received.removeAll()        // drop the replay blob; the burst is what matters

        vm.receiveOutput(Data([0x41]))            // narrow-width frame
        try await Task.sleep(for: .milliseconds(80))
        vm.receiveOutput(Data([0x42]))            // full-width frame
        XCTAssertTrue(received.isEmpty, "Output must be held while coalescing")

        try await waitFor(timeout: .milliseconds(600)) { !received.isEmpty }
        XCTAssertEqual(received.count, 1, "Coalesced burst must deliver exactly once")
        XCTAssertEqual(received[0], Data([0x41, 0x42]))
    }

    /// Once the post-replay burst has flushed, normal live output resumes
    /// immediately (no lingering buffering).
    func testOutputResumesLiveAfterReloadFlush() async throws {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        vm.beginServerReload()
        vm.endReplay()
        vm.receiveOutput(Data([0x41]))
        try await waitFor(timeout: .milliseconds(600)) { received.count > 1 }
        received.removeAll()

        vm.receiveOutput(Data([0x43]))
        XCTAssertEqual(received, [Data([0x43])])
    }

    /// The coordinator reads this to drop a re-tap, so it must stay true for the
    /// whole in-flight window — the RPC returns just BEFORE `replay_complete`.
    func testIsReloadingFromServerTracksTheInFlightWindow() {
        let vm = makeVM()
        vm.onTerminalOutput = { _ in }
        vm.terminalReady()

        XCTAssertFalse(vm.isReloadingFromServer)
        vm.beginServerReload()
        XCTAssertTrue(vm.isReloadingFromServer)
        vm.endReplay()
        XCTAssertFalse(vm.isReloadingFromServer)
    }

    /// The fade-through-black cover is held up by observing this flag, so it has
    /// to PUBLISH, not merely read true: as a plain computed property (what it
    /// was) the views get no notification and the pane stays black until their
    /// timeout. Pins the whole edge sequence a subscriber sees.
    func testIsReloadingFromServerPublishesEachEdge() async {
        let vm = makeVM()
        var paints = [Data]()
        vm.onTerminalOutput = { paints.append($0) }
        vm.terminalReady()

        var emitted = [Bool]()
        let subscription = vm.$isReloadingFromServer.sink { emitted.append($0) }
        defer { subscription.cancel() }

        vm.beginServerReload()
        vm.receiveOutput(Data([0x41]))
        vm.endReplay()

        // Current value on subscribe, then the tap, then the landed replay.
        XCTAssertEqual(emitted, [false, true, false])
        // And the screen the cover lifts on is the replayed one: `endReplay` has
        // already flushed RIS + the buffered blob by the time it returns, which is
        // strictly before an awaiting task can resume on this actor.
        XCTAssertEqual(paints, [Data([0x1B, 0x63, 0x41])])
    }

    /// A reload whose resume never reached the server must leave the pane
    /// showing what it had — cancelling drops the pending clear.
    func testCancelServerReloadKeepsTheExistingScreen() {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        vm.beginServerReload()
        vm.cancelServerReload()

        XCTAssertTrue(received.isEmpty, "Cancelled reload must not emit RIS")

        // And buffering is released, so live output flows again.
        vm.receiveOutput(Data([0x43]))
        XCTAssertEqual(received, [Data([0x43])])
    }

    func testSendInputClearsAwaitingInput() async throws {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        vm.receiveOutput(Data([0x24, 0x20]))
        try await waitFor { vm.awaitingInput }
        XCTAssertTrue(vm.awaitingInput)

        vm.sendInput(Data([0x0A]))
        XCTAssertFalse(vm.awaitingInput)
    }

    func testAwaitingInputCallbackFires() async throws {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        var transitions = [Bool]()
        vm.onAwaitingInputChanged = { transitions.append($0) }

        vm.receiveOutput(Data([0x24, 0x20]))
        try await waitFor { !transitions.isEmpty }

        XCTAssertEqual(transitions, [true])
    }

    func testAgentActiveUsesLongerThreshold() async throws {
        // Override default thresholds with a wider agentActive margin so the
        // "hasn't fired yet" assertion has room against CI jitter. The
        // invariant is still "normal < agentActive"; the specific numbers
        // are only there to keep the negative-case sleep well short of the
        // agentActive threshold.
        let vm = makeVM(normal: .milliseconds(80), agentActive: .milliseconds(500))
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()
        vm.isAgentActive = true

        vm.receiveOutput(Data([0x24, 0x20]))
        // 150 ms is deep inside the agentActive threshold (500 ms) — assert
        // the timer has NOT fired yet. Can't be polled; needs a hard deadline.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(vm.awaitingInput, "Should not trigger before agentActive threshold")

        // Now poll for the positive transition — the happy path doesn't pay
        // the full 500 ms wait unless jitter is extreme.
        try await waitFor(timeout: .milliseconds(1000)) { vm.awaitingInput }
        XCTAssertTrue(vm.awaitingInput, "Should trigger after agentActive threshold elapses")
    }

    func testPendingOutputByteCapEvictsOldest() {
        let vm = makeVM()
        // 80 × 64 KB = 5 MB, exceeding the 4 MB cap.
        let chunk = Data(repeating: 0x41, count: 64 * 1024)
        for _ in 0..<80 {
            vm.receiveOutput(chunk)
        }

        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        let totalBytes = received.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(totalBytes, 4 * 1024 * 1024 + 64 * 1024,
            "pending buffer should have been capped at ~4MB + one overshoot chunk")
        XCTAssertGreaterThan(totalBytes, 3 * 1024 * 1024,
            "cap should keep at least ~3 MB of recent output")
    }

    /// Boundary case: buffering data up to *exactly* the 4 MB cap must not
    /// evict anything. The eviction path only runs when size *exceeds* the cap.
    func testPendingOutputExactlyAtCapDoesNotEvict() {
        let vm = makeVM()
        // 4 × 1 MB = 4 MB, exactly at the cap.
        let chunk = Data(repeating: 0x42, count: 1024 * 1024)
        for _ in 0..<4 {
            vm.receiveOutput(chunk)
        }

        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        let total = received.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, 4 * 1024 * 1024,
            "All 4 MB should be preserved when buffer is at cap (but not over)")
    }

    /// Boundary case: buffering slightly over the cap must evict the oldest
    /// chunks so the total stays within cap + one head-chunk slack.
    func testPendingOutputOverCapDropsOldestChunks() {
        let vm = makeVM()
        let chunk = Data(repeating: 0x43, count: 64 * 1024)     // 64 KB
        for _ in 0..<80 {                                        // 5 MB > 4 MB cap
            vm.receiveOutput(chunk)
        }

        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        let total = received.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(total, 4 * 1024 * 1024 + chunk.count,
            "Total delivered should stay within cap + one head chunk slack")
    }

    // MARK: - Send Suppression

    func testSendInputSuppressedWhenFlagSet() {
        let connection = RelayConnection()
        let vm = TerminalViewModel(sessionId: UUID(), connection: connection)
        vm.isSendingSuppressed = true

        // sendInput should be a no-op — no crash, no throws
        vm.sendInput(Data([0x41, 0x42]))
        vm.sendInput("hello")
    }

    func testSendInputWorksWhenNotSuppressed() {
        let connection = RelayConnection()
        let vm = TerminalViewModel(sessionId: UUID(), connection: connection)
        vm.isSendingSuppressed = false

        // Can't verify the send reaches the connection (it's disconnected),
        // but it should not crash
        vm.sendInput(Data([0x41]))
        vm.sendInput("test")
    }

    // MARK: - Empty data

    func testReceiveOutputEmptyDataNoCrash() {
        let vm = makeVM()
        var received = [Data]()
        vm.onTerminalOutput = { received.append($0) }
        vm.terminalReady()

        vm.receiveOutput(Data())
        // Should not crash or produce output for empty data
    }

    // MARK: - String sendInput encoding

    func testSendInputStringConvertsToUTF8() {
        let connection = RelayConnection()
        let vm = TerminalViewModel(sessionId: UUID(), connection: connection)
        // This should not crash — we can't verify the bytes reach the wire
        // since the connection is disconnected, but encoding should be correct
        vm.sendInput("hello")
    }
}
