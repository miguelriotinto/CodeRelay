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
