import XCTest
import Foundation
@testable import CodeRelayKit
@testable import CodeRelayServer

/// Live probe: which chords insert a newline in each installed agent's input
/// box, and which submit? Gated on CODERELAY_PROBE_AGENTS=1 because it launches
/// real agents. Output is a table for a human to copy into the manifests.
///
///   CODERELAY_PROBE_AGENTS=1 swift test --filter AgentInputProfileProbeTests 2>&1 | grep PROBE
final class AgentInputProfileProbeTests: XCTestCase {

    private struct Candidate {
        let key: String        // InputKey raw value
        let bytes: Data
    }

    private static let candidates: [Candidate] = [
        Candidate(key: "shift_enter",     bytes: Data("\u{1B}[13;2u".utf8)),      // kitty CSI u
        Candidate(key: "ctrl_enter",      bytes: Data("\u{1B}[13;5u".utf8)),
        Candidate(key: "alt_enter",       bytes: Data("\u{1B}\r".utf8)),           // ESC CR
        Candidate(key: "backslash_enter", bytes: Data("\\\r".utf8)),
    ]

    private static let agents: [(id: String, paths: [String])] = [
        ("claude",       ["/opt/homebrew/bin/claude"]),
        ("codex",        [NSString(string: "~/.local/bin/codex").expandingTildeInPath, "/opt/homebrew/bin/codex"]),
        ("opencode",     ["/opt/homebrew/bin/opencode", NSString(string: "~/.local/bin/opencode").expandingTildeInPath]),
        ("copilot",      ["/opt/homebrew/bin/copilot", NSString(string: "~/.local/bin/copilot").expandingTildeInPath]),
        ("cursor-agent", ["/opt/homebrew/bin/cursor-agent", NSString(string: "~/.local/bin/cursor-agent").expandingTildeInPath]),
        ("droid",        ["/opt/homebrew/bin/droid", NSString(string: "~/.local/bin/droid").expandingTildeInPath]),
    ]

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CODERELAY_PROBE_AGENTS"] == "1",
                          "set CODERELAY_PROBE_AGENTS=1 to run the live agent probe")
    }

    func testProbeInstalledAgents() async throws {
        for agent in Self.agents {
            guard let path = agent.paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                print("PROBE \(agent.id): SKIPPED (not installed)")
                continue
            }
            print("PROBE \(agent.id): \(path) \(version(of: path))")
            for candidate in Self.candidates {
                let verdict = await probe(agentId: agent.id, command: path, chord: candidate)
                print("PROBE \(agent.id) \(candidate.key.padding(toLength: 16, withPad: " ", startingAt: 0)) → \(verdict)")
            }
        }
    }

    private func version(of path: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return "(version unknown)" }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One fresh agent per chord. Returns "newline", "submit", or a diagnostic.
    private func probe(agentId: String, command: String, chord: Candidate) async -> String {
        let pty: PTYSession
        do {
            pty = try PTYSession(sessionId: UUID(), cols: 100, rows: 30, scrollbackSize: 65_536, adminPort: 9100)
        } catch {
            return "could not spawn: \(error)"
        }
        defer { Task { await pty.terminate() } }
        await pty.startReading()

        // Wait for shell prompt
        try? await Task.sleep(for: .milliseconds(2000))

        // Launch the agent in /tmp to avoid trust prompts
        await pty.write(Data("cd /tmp && \(command)\r".utf8))

        // Wait for the agent to come up and be recognised as idle.
        let booted = await poll(.seconds(60)) {
            let activeAgent = await pty.getActiveAgent()
            let agentState = await pty.getAgentState()
            return activeAgent?.id == agentId && agentState == .idle
        }
        guard booted else {
            let activeAgent = await pty.getActiveAgent()
            let agentState = await pty.getAgentState()
            return "agent never reached idle (active=\(activeAgent?.id ?? "nil") state=\(String(describing: agentState)))"
        }

        await pty.write(Data("alpha".utf8))
        try? await Task.sleep(for: .milliseconds(400))
        await pty.write(chord.bytes)
        try? await Task.sleep(for: .milliseconds(400))
        await pty.write(Data("beta".utf8))

        // A submit shows up as the agent leaving idle; a newline leaves it idle
        // with both words on screen.
        let submitted = await poll(.seconds(4)) {
            let agentState = await pty.getAgentState()
            return agentState != .idle
        }
        let screen = await pty.promptContext(includeScreen: true).screenLines
        let tail = screen.suffix(6).joined(separator: " ⏎ ")
        if submitted {
            await pty.write(Data("\u{1B}".utf8))   // Escape: interrupt whatever "alpha" started
            return "submit        | \(tail)"
        }
        let bothVisible = screen.contains { $0.contains("alpha") } && screen.contains { $0.contains("beta") }
        let sameLine = screen.contains { $0.contains("alpha") && $0.contains("beta") }
        if bothVisible && !sameLine { return "newline       | \(tail)" }
        if sameLine { return "no effect     | \(tail)" }
        return "unclear       | \(tail)"
    }

    private func poll(_ deadline: Duration, until condition: @escaping () async -> Bool) async -> Bool {
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }
}
