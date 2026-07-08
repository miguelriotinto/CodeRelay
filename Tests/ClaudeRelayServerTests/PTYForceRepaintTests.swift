import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

/// Exercises the REAL `PTYSession.forceRepaint()` against a live shell.
///
/// Regression context: the original implementation sent a bare SIGWINCH at
/// unchanged size. Node/Ink apps (Claude Code) re-query TIOCGWINSZ in their
/// WINCH handler and skip the redraw when the dimensions match their cache —
/// so tap-to-redraw delivered a signal that the target app ignored. The mock
/// tests couldn't catch that: they only assert the call happened. This test
/// asserts the observable contract instead: the foreground process sees a
/// genuine size change AND the size ends up restored.
final class PTYForceRepaintTests: XCTestCase {

    private var pty: PTYSession?

    override func tearDown() async throws {
        if let pty {
            await pty.terminate()
        }
        pty = nil
    }

    /// Collects PTY output until `marker` appears or `timeout` elapses.
    private func waitForOutput(
        containing marker: String,
        in collector: OutputCollector,
        timeout: TimeInterval
    ) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = await collector.text
            if text.contains(marker) { return text }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await collector.text
    }

    func testForceRepaintDeliversRealSizeChangeAndRestores() async throws {
        let session = try PTYSession(
            sessionId: UUID(),
            cols: 120,
            rows: 40,
            scrollbackSize: 64 * 1024
        )
        pty = session

        let collector = OutputCollector()
        await session.setOutputHandler { data in
            Task { await collector.append(data) }
        }
        await session.startReading()

        // Install a WINCH trap that reports the size the shell observes.
        // `zsh` updates COLUMNS from TIOCGWINSZ on WINCH, so each real size
        // change prints one WINCH:<cols> line. A same-size SIGWINCH (the old
        // broken behavior) prints WINCH:120 twice or nothing useful — the
        // assertion below requires the *intermediate* width to be observed.
        await session.write(Data("trap 'echo WINCH:$COLUMNS' WINCH; echo TRAP_READY\n".utf8))
        let readyText = await waitForOutput(containing: "TRAP_READY", in: collector, timeout: 5.0)
        // Shell may not have come up (e.g. sandboxed CI without login) — skip
        // rather than fail on environmental issues.
        try XCTSkipIf(!readyText.contains("TRAP_READY"), "shell did not initialize in time")
        await collector.reset()

        // The wiggle must surface the intermediate width (119) to the child —
        // that observation is exactly what Node keys its redraw on. Retry a
        // few times: under full-suite CPU load the shell can be scheduled too
        // late to see the intermediate size within one wiggle (a user would
        // tap again). A regression back to bare same-size SIGWINCH fails
        // deterministically — no attempt can ever produce WINCH:119 because
        // the size never changes.
        var text = ""
        for _ in 0..<5 {
            await session.forceRepaint()
            text = await waitForOutput(containing: "WINCH:119", in: collector, timeout: 2.0)
            if text.contains("WINCH:119") { break }
        }
        XCTAssertTrue(
            text.contains("WINCH:119"),
            "foreground process never observed the intermediate size — repaint would be skipped by Node/Ink apps. Output: \(text)"
        )

        // And the size must be restored afterwards.
        await session.write(Data("echo FINAL:$COLUMNS\n".utf8))
        let finalText = await waitForOutput(containing: "FINAL:120", in: collector, timeout: 5.0)
        XCTAssertTrue(
            finalText.contains("FINAL:120"),
            "size was not restored after the wiggle. Output: \(finalText)"
        )
    }

    func testForceRepaintRestoresToNewestSizeWhenResizedMidWiggle() async throws {
        let session = try PTYSession(
            sessionId: UUID(),
            cols: 120,
            rows: 40,
            scrollbackSize: 64 * 1024
        )
        pty = session

        let collector = OutputCollector()
        await session.setOutputHandler { data in
            Task { await collector.append(data) }
        }
        await session.startReading()

        await session.write(Data("echo SHELL_READY\n".utf8))
        let readyText = await waitForOutput(containing: "SHELL_READY", in: collector, timeout: 5.0)
        try XCTSkipIf(!readyText.contains("SHELL_READY"), "shell did not initialize in time")
        await collector.reset()

        // Race a client resize against the wiggle's 50 ms sleep. Whatever the
        // interleaving, the actor serializes the calls and forceRepaint's
        // restore must use the NEWEST size (90), never stomp it back to 120.
        async let repaint: Void = session.forceRepaint()
        await session.resize(cols: 90, rows: 40)
        _ = await repaint

        await session.write(Data("echo FINAL:$COLUMNS\n".utf8))
        let finalText = await waitForOutput(containing: "FINAL:90", in: collector, timeout: 5.0)
        XCTAssertTrue(
            finalText.contains("FINAL:90"),
            "mid-wiggle resize was stomped by forceRepaint's restore. Output: \(finalText)"
        )
    }
}

/// Actor that accumulates PTY output for assertions.
private actor OutputCollector {
    private var buffer = Data()

    var text: String {
        String(bytes: buffer, encoding: .utf8) ?? ""
    }

    func append(_ data: Data) {
        buffer.append(data)
    }

    func reset() {
        buffer.removeAll()
    }
}
