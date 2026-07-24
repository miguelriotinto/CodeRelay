import XCTest
@testable import ClaudeRelayKit

final class CodingAgentTests: XCTestCase {

    // MARK: - Process Name Matching

    func testClaudeExactMatch() {
        XCTAssertTrue(CodingAgent.claude.matchesProcessName("claude"))
    }

    func testClaudePrefixMatch() {
        XCTAssertTrue(CodingAgent.claude.matchesProcessName("claude-code"))
    }

    func testClaudeCaseInsensitive() {
        XCTAssertTrue(CodingAgent.claude.matchesProcessName("Claude"))
    }

    func testClaudeNoFalsePositive() {
        XCTAssertFalse(CodingAgent.claude.matchesProcessName("claudette"))
    }

    func testClaudeExeExtension() {
        XCTAssertTrue(CodingAgent.claude.matchesProcessName("claude.exe"))
    }

    /// The prefix rule (`lower.hasPrefix("claude-")`) unavoidably matches the server
    /// binary name `claude-relay-server`. `PTYSession.detectAgentInProcessChain`
    /// compensates by stopping the parent walk at our own PID — without that guard,
    /// every fresh PTY (login → zsh → claude-relay-server) would look like Claude
    /// is running from the moment the shell starts.
    func testClaudeMatchesServerBinary_guardedByPIDCheck() {
        XCTAssertTrue(CodingAgent.claude.matchesProcessName("claude-relay-server"))
    }

    func testCodexExactMatch() {
        XCTAssertTrue(CodingAgent.codex.matchesProcessName("codex"))
    }

    func testCodexPrefixMatch() {
        XCTAssertTrue(CodingAgent.codex.matchesProcessName("codex-cli"))
    }

    func testCodexJsExtension() {
        XCTAssertTrue(CodingAgent.codex.matchesProcessName("codex.js"))
    }

    func testCodexDoesNotMatchClaude() {
        XCTAssertFalse(CodingAgent.codex.matchesProcessName("claude"))
    }

    // MARK: - Title Matching

    func testClaudeTitleMatch() {
        XCTAssertTrue(CodingAgent.claude.matchesTitle("~/project — Claude Code"))
    }

    func testClaudeTitleCaseInsensitive() {
        XCTAssertTrue(CodingAgent.claude.matchesTitle("CLAUDE running"))
    }

    func testCodexTitleMatch() {
        XCTAssertTrue(CodingAgent.codex.matchesTitle("Codex session"))
    }

    func testUnrelatedTitle() {
        XCTAssertFalse(CodingAgent.claude.matchesTitle("vim editor"))
        XCTAssertFalse(CodingAgent.codex.matchesTitle("vim editor"))
    }

    // MARK: - Registry Lookups

    func testFindById() {
        XCTAssertEqual(CodingAgent.find(id: "claude"), .claude)
        XCTAssertEqual(CodingAgent.find(id: "codex"), .codex)
        XCTAssertNil(CodingAgent.find(id: "unknown"))
    }

    func testMatchingProcessName() {
        XCTAssertEqual(CodingAgent.matching(processName: "claude"), .claude)
        XCTAssertEqual(CodingAgent.matching(processName: "codex"), .codex)
        XCTAssertNil(CodingAgent.matching(processName: "vim"))
    }

    func testMatchingTitle() {
        XCTAssertEqual(CodingAgent.matching(title: "Claude Code — ~/project"), .claude)
        XCTAssertEqual(CodingAgent.matching(title: "codex interactive"), .codex)
        XCTAssertNil(CodingAgent.matching(title: "zsh"))
    }

    func testRegistryPriorityOrderMatters() {
        // If a title contains both keywords, first registered agent wins.
        // This is a deliberate design: .claude is first in .all.
        let agent = CodingAgent.matching(title: "claude and codex")
        XCTAssertEqual(agent, .claude)
    }

    func testOpencodeIsRegistered() {
        XCTAssertNotNil(CodingAgent.find(id: "opencode"))
        XCTAssertEqual(CodingAgent.matching(processName: "opencode")?.id, "opencode")
        XCTAssertEqual(CodingAgent.matching(title: "opencode session")?.id, "opencode")
    }

    func testAllContainsRegisteredAgents() {
        XCTAssertEqual(Set(CodingAgent.all.map { $0.id }),
                       ["claude", "codex", "opencode", "copilot", "cursor-agent", "droid"])
    }

    // MARK: - F5 new agents

    func testCopilotMatch() {
        XCTAssertEqual(CodingAgent.matching(processName: "copilot")?.id, "copilot")
        XCTAssertEqual(CodingAgent.matching(title: "Copilot CLI")?.id, "copilot")
        XCTAssertEqual(CodingAgent.find(id: "copilot")?.displayName, "Copilot CLI")
    }

    func testCursorAgentMatch() {
        XCTAssertEqual(CodingAgent.matching(processName: "cursor-agent")?.id, "cursor-agent")
        // Cursor's installer also symlinks the binary as `agent`.
        XCTAssertEqual(CodingAgent.matching(processName: "agent")?.id, "cursor-agent")
        XCTAssertEqual(CodingAgent.find(id: "cursor-agent")?.displayName, "Cursor Agent")
    }

    func testCursorAgentGenericNameDoesNotSubstringMatch() {
        // `agent` matches only by strict equality / `-` prefix, never as a
        // substring — so unrelated binaries like `agentd` don't false-match.
        XCTAssertNil(CodingAgent.matching(processName: "agentd"))
        XCTAssertNil(CodingAgent.matching(processName: "myagent"))
    }

    func testDroidMatch() {
        XCTAssertEqual(CodingAgent.matching(processName: "droid")?.id, "droid")
        XCTAssertEqual(CodingAgent.matching(title: "Droid — Factory")?.id, "droid")
        // Title matching is substring-based: the generic word "factory" must
        // NOT classify an ordinary session as Droid (e.g. a "factory-service"
        // directory title). Only the specific "droid" keyword matches.
        XCTAssertNil(CodingAgent.matching(title: "factory-service — zsh"))
        XCTAssertEqual(CodingAgent.find(id: "droid")?.displayName, "Droid")
    }
}
