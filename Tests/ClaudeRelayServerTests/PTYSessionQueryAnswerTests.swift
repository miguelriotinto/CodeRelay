import Foundation
import XCTest
@testable import ClaudeRelayServer

/// Pins the seam where PTY output splits into *history* and the *live client
/// stream* — the one place a terminal query can escape to a device.
///
/// Regression: a query (`ESC ] 11 ; ? BEL` from a Go TUI probing the background
/// colour, `ESC [ 6 n` from anything tracking the cursor) used to be forwarded
/// verbatim. The device's SwiftTerm answered it a WebSocket round trip later —
/// after the asking program had stopped reading — so the shell's line editor took
/// the answer as keystrokes and echoed its payload at the prompt:
/// `11;rgb:0000/0000/0000`. Both assertions below fail against that code.
///
/// The answer half of the fix (this server emulator producing the reply) is
/// pinned by `TerminalScreenModelTests`; what these add is that the query is gone
/// from **both** client-bound copies, which is what stops the device answering.
final class PTYSessionQueryAnswerTests: XCTestCase {

    /// Collects forwarded output across the read source's queue and the actor.
    /// `outputHandler` is `@Sendable`, so a captured `var` won't do.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            bytes.append(data)
        }
        var collected: Data {
            lock.lock(); defer { lock.unlock() }
            return bytes
        }
    }

    private var pty: PTYSession?

    override func tearDown() async throws {
        if let pty { await pty.terminate() }
        pty = nil
    }

    private func makeSession() throws -> PTYSession {
        let session = try PTYSession(sessionId: UUID(), cols: 80, rows: 24, scrollbackSize: 64 * 1024)
        pty = session
        return session
    }

    /// A colour query — the exact sequence from the reported bug.
    private let query = Data("\u{1B}]11;?\u{07}".utf8)

    /// Subsequence search: `Data.contains` tests single bytes, not sequences.
    private func holds(_ haystack: Data, _ needle: Data) -> Bool {
        haystack.range(of: needle) != nil
    }

    func testQueryIsStrippedFromTheLiveClientStream() async throws {
        let session = try makeSession()
        let sink = Sink()
        await session.setOutputHandler { sink.append($0) }

        await session._testOnly_handleOutput(Data("ready".utf8) + query + Data("done".utf8))

        let forwarded = sink.collected
        XCTAssertFalse(holds(forwarded, query),
                       "the query reached the device, which will answer it a round trip too late")
        // Surrounding output must survive — a filter that ate the payload would
        // pass the assertion above for the wrong reason.
        XCTAssertTrue(holds(forwarded, Data("ready".utf8)) && holds(forwarded, Data("done".utf8)),
                      "output around the query must be forwarded byte-exact")
    }

    /// History is the second client-bound copy: replayed on attach/resume and on
    /// the session-name tap. A query surviving here is answered later, which is
    /// how stale replies ended up in scrollback in the first place.
    func testQueryIsStrippedFromReplayableHistory() async throws {
        let session = try makeSession()

        await session._testOnly_handleOutput(Data("ready".utf8) + query + Data("done".utf8))

        let history = await session.readBuffer()
        XCTAssertFalse(holds(history, query), "a replay of this history would provoke a late answer")
        XCTAssertTrue(holds(history, Data("ready".utf8)), "history must still hold the real output")
    }

    /// Detection must keep seeing the raw stream: it is what produces the answer,
    /// and stripping before it would leave the query unanswered by anyone.
    func testOrdinaryOutputIsUntouched() async throws {
        let session = try makeSession()
        let sink = Sink()
        await session.setOutputHandler { sink.append($0) }

        let plain = Data("\u{1B}[1;31mred\u{1B}[0m \u{1B}]0;title\u{07}\n".utf8)
        await session._testOnly_handleOutput(plain)

        XCTAssertTrue(holds(sink.collected, plain),
                      "non-query escapes must pass through unmodified")
    }
}
