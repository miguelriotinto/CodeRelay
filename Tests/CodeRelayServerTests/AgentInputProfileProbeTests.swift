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

    private struct ProbeResult {
        let newlineChords: [String]
        let inset: Int?
        let killLineAcrossLines: Bool?
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

            var newlineChords: [String] = []

            // Probe each chord
            for candidate in Self.candidates {
                let verdict = await probeChord(agentId: agent.id, command: path, chord: candidate)
                print("PROBE \(agent.id) \(candidate.key.padding(toLength: 16, withPad: " ", startingAt: 0)) → \(verdict)")
                if verdict.hasPrefix("newline") {
                    newlineChords.append(candidate.key)
                }
            }

            // Measure inset and test killLineAcrossLines if any newline chord exists
            if !newlineChords.isEmpty, let firstNewline = Self.candidates.first(where: { newlineChords.contains($0.key) }) {
                let inset = await probeInset(agentId: agent.id, command: path)
                print("PROBE \(agent.id) inset            → \(inset)")

                let killLine = await probeKillLineAcrossLines(agentId: agent.id, command: path, newlineChord: firstNewline)
                print("PROBE \(agent.id) killLineAcrossLines → \(killLine)")
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

    /// Launch agent in a PTY, wait for idle, run the probe body, then terminate.
    private func withAgent(
        agentId: String,
        command: String,
        body: (PTYSession) async -> String
    ) async -> String {
        let pty: PTYSession
        do {
            pty = try PTYSession(sessionId: UUID(), cols: 100, rows: 30, scrollbackSize: 65_536, adminPort: 9100)
        } catch {
            return "could not spawn: \(error)"
        }

        let result = await _withAgentBody(pty: pty, agentId: agentId, command: command, body: body)
        await pty.terminate()
        return result
    }

    private func _withAgentBody(
        pty: PTYSession,
        agentId: String,
        command: String,
        body: (PTYSession) async -> String
    ) async -> String {
        await pty.startReading()

        // Wait for shell prompt
        try? await Task.sleep(for: .milliseconds(2000))

        // Launch the agent in the repo root (swift test runs from package root).
        // The root is already trusted in ~/.claude.json, avoiding workspace-trust prompts.
        let cwd = FileManager.default.currentDirectoryPath
        let quotedCwd = cwd.replacingOccurrences(of: "'", with: "'\\''")
        await pty.write(Data("cd '\(quotedCwd)' && \(command)\r".utf8))

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

        return await body(pty)
    }

    /// Test one chord: does it insert a newline or submit?
    private func probeChord(agentId: String, command: String, chord: Candidate) async -> String {
        return await withAgent(agentId: agentId, command: command) { pty in
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
    }

    /// Measure inset as wrap width: inset = columns - maxRowGlyphCount.
    /// Type 130 glyphs (more than PTY width of 100) and count glyphs in the row
    /// holding the MOST of them (the first wrapped row, not a continuation).
    private func probeInset(agentId: String, command: String) async -> String {
        return await withAgent(agentId: agentId, command: command) { pty in
            // Type 130 Q's in chunks of 10 with gaps to avoid paste detection.
            // Q is chosen because it never appears in agent UI text.
            for _ in 0..<13 {
                await pty.write(Data("QQQQQQQQQQ".utf8))
                try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(500))

            let screen = await pty.promptContext(includeScreen: true).screenLines
            let tail = screen.suffix(6).joined(separator: " ⏎ ")

            // Find the row with the MOST Qs (the first wrapped row holds full width)
            let rowCounts = screen.map { row -> (row: String, count: Int) in
                (row, row.filter { $0 == "Q" }.count)
            }.filter { $0.count > 0 }

            guard let maxRow = rowCounts.max(by: { $0.count < $1.count }) else {
                return "could not find 'Q' | \(tail)"
            }

            let maxCount = maxRow.count
            let leftColumn = maxRow.row.firstIndex(of: "Q").map { maxRow.row.distance(from: maxRow.row.startIndex, to: $0) } ?? 0

            // Sanity check: wrap width must be reasonable (20-100)
            guard maxCount >= 20 && maxCount <= 100 else {
                return "unclear (max row holds \(maxCount))"
            }

            let inset = 100 - maxCount
            return "\(inset) (first row holds \(maxCount) glyphs, text starts at column \(leftColumn))"
        }
    }

    /// Does Ctrl-U (kill line) remove a newline inserted by a newline chord?
    /// After alpha+newline, cursor is on empty second line. One Ctrl-U:
    /// - true: removes the newline, cursor after alpha, Z lands as alphaZ
    /// - false: does nothing at line start, Z goes on separate row
    private func probeKillLineAcrossLines(agentId: String, command: String, newlineChord: Candidate) async -> String {
        return await withAgent(agentId: agentId, command: command) { pty in
            await pty.write(Data("alpha".utf8))
            try? await Task.sleep(for: .milliseconds(400))
            await pty.write(newlineChord.bytes)
            try? await Task.sleep(for: .milliseconds(400))

            // Send ONE Ctrl-U
            await pty.write(Data([0x15]))  // Ctrl-U
            try? await Task.sleep(for: .milliseconds(400))

            await pty.write(Data("Z".utf8))
            try? await Task.sleep(for: .milliseconds(400))

            let screen = await pty.promptContext(includeScreen: true).screenLines
            let tail = screen.suffix(6).joined(separator: " ⏎ ")

            // Verdict: alphaZ on one row → true; alpha and Z on different rows → false; Z alone → false
            if screen.contains(where: { $0.contains("alphaZ") }) {
                return "true          | \(tail)"
            }
            if screen.contains(where: { $0.contains("alpha") }) && screen.contains(where: { $0.contains("Z") }) {
                // Check if they're on different rows
                let alphaRows = screen.enumerated().filter { $0.element.contains("alpha") }.map { $0.offset }
                let zRows = screen.enumerated().filter { $0.element.contains("Z") }.map { $0.offset }
                if Set(alphaRows).isDisjoint(with: Set(zRows)) {
                    return "false         | \(tail)"
                }
            }
            if !screen.contains(where: { $0.contains("alpha") }) {
                return "false         | \(tail)"
            }
            return "unclear       | \(tail)"
        }
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
