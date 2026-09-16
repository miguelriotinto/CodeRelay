import XCTest
import SwiftTerm
@testable import CodeRelayServer

/// Drives a real login shell: the draft mirror follows bytes written through
/// `write`, and the screen-model flags follow what the shell prints.
final class PTYSessionPromptContextTests: XCTestCase {
    private var session: PTYSession?

    override func tearDown() async throws {
        if let session { await session.terminate() }
        session = nil
    }

    private func poll(_ deadline: Duration = .seconds(8), until condition: () async -> Bool) async -> Bool {
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    private func startedSession() async throws -> PTYSession {
        let session = try PTYSession(sessionId: UUID(), cols: 80, rows: 24, scrollbackSize: 8192)
        self.session = session
        await session.setOutputHandler { _ in }
        await session.startReading()
        // Wait for the shell prompt to render before typing into it.
        let ready = await poll { await !session.promptContext(includeScreen: true).screenLines.isEmpty }
        XCTAssertTrue(ready, "shell never rendered a prompt")
        return session
    }

    func testDraftFollowsWritesAndSubmitClearsIt() async throws {
        let session = try await startedSession()

        await session.write(Data("echo hel".utf8))
        await session.write(Data("lo".utf8))
        var ctx = await session.promptContext(includeScreen: false)
        XCTAssertEqual(ctx.draft, "echo hello")
        XCTAssertNil(ctx.agentId)
        XCTAssertTrue(ctx.screenLines.isEmpty)

        await session.write(Data([0x0D]))
        ctx = await session.promptContext(includeScreen: true)
        XCTAssertEqual(ctx.draft, "")
        let echoed = await poll { await session.promptContext(includeScreen: true).screenLines.contains { $0 == "hello" } }
        XCTAssertTrue(echoed, "screen never showed the echoed line")
    }

    /// G1 through the real actor: the replacement is sized from the mirror as the
    /// actor holds it and adopts its own text, so the very next optimize/Undo has
    /// an exact mirror again without waiting for a submit.
    func testReplaceDraftAdoptsItsOwnTextOnAKnownMirror() async throws {
        let session = try await startedSession()

        await session.write(Data("echo hello".utf8))
        var ctx = await session.promptContext(includeScreen: false)
        XCTAssertEqual(ctx.draft, "echo hello")
        XCTAssertTrue(ctx.draftKnown)

        let outcome = await session.replaceDraft(with: "echo bye", forAgent: .any)
        // B-6: the outcome reports the draft the actor actually erased, which is
        // what the `ok` reply hands the client as `original`.
        XCTAssertEqual(outcome, .replaced(erased: "echo hello"))
        ctx = await session.promptContext(includeScreen: false)
        XCTAssertEqual(ctx.draft, "echo bye")
        XCTAssertTrue(ctx.draftKnown)

        // The adopted mirror accumulates normally from here.
        await session.write(Data("!".utf8))
        ctx = await session.promptContext(includeScreen: false)
        XCTAssertEqual(ctx.draft, "echo bye!")
    }

    /// G1 / re-review Important 1+2: an Up on a single-row draft is history
    /// navigation, so the mirror is lost. The actor — not the handler's stale
    /// snapshot — refuses: nothing is typed and the mirror stays lost, because an
    /// erase sized from a mirror it cannot count would paste into the residue.
    func testReplaceDraftRefusesOnALostMirrorAndTypesNothing() async throws {
        let session = try await startedSession()

        await session.write(Data("echo hello".utf8))
        let typed = await session.promptContext(includeScreen: false)
        XCTAssertTrue(typed.draftKnown)

        await session.write(Data([0x1B, 0x5B, 0x41]))          // CSI A — Up: history
        var ctx = await session.promptContext(includeScreen: false)
        XCTAssertEqual(ctx.draft, "")
        XCTAssertFalse(ctx.draftKnown)

        let outcome = await session.replaceDraft(with: "echo bye", forAgent: .any)
        XCTAssertEqual(outcome, .refused, "a lost mirror must refuse the replacement")
        ctx = await session.promptContext(includeScreen: false)
        XCTAssertEqual(ctx.draft, "")
        XCTAssertFalse(ctx.draftKnown, "a refused replacement must not adopt anything")
    }

    func testScreenFlagsFollowWhatTheShellPrints() async throws {
        let session = try await startedSession()

        await session.write(Data("printf '\\e[?2004h\\e[>1u'\r".utf8))
        let armed = await poll {
            let c = await session.promptContext(includeScreen: false)
            return c.bracketedPaste && c.keyboardFlags.contains(.disambiguate)
        }
        XCTAssertTrue(armed)

        // Keep shell busy so poll can observe the cleared flags before zsh's prompt
        // redraw re-arms bracketed paste (zle_bracketed_paste runs on every prompt).
        await session.write(Data("printf '\\e[?2004l\\e[<u'; sleep 3\r".utf8))
        let released = await poll {
            let c = await session.promptContext(includeScreen: false)
            return !c.bracketedPaste && c.keyboardFlags.isEmpty
        }
        XCTAssertTrue(released)
    }
}
