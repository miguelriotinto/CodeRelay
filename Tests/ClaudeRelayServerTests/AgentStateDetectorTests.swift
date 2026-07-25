import XCTest
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class AgentStateDetectorTests: XCTestCase {

    private func snap(_ text: String, oscTitle: String = "", oscProgress: String = "") -> ScreenSnapshot {
        ScreenSnapshot(text: text, oscTitle: oscTitle, oscProgress: oscProgress)
    }

    // MARK: - Bundled manifests load

    func testBundledManifestsLoad() {
        let manifests = AgentStateDetector.loadBundled()
        XCTAssertNotNil(manifests["claude"])
        XCTAssertNotNil(manifests["codex"])
        XCTAssertNotNil(manifests["opencode"])
        XCTAssertNotNil(manifests["copilot"])
        XCTAssertNotNil(manifests["cursor-agent"])
        XCTAssertNotNil(manifests["droid"])
    }

    // MARK: - cursor-agent rules (fully binary-verified patterns)

    func testCursorBlockedOnCommandApproval() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        Run this command?
          rm -rf build/
        Allow once   Allow always   Reject
        ↑↓ to select • Enter to confirm • Esc to cancel
        """
        let detection = detector.detect(agentId: "cursor-agent", snapshot: snap(screen))
        XCTAssertEqual(detection?.state, .blocked)
        XCTAssertTrue(detection?.visibleBlocker ?? false)
    }

    func testCursorWorkingFromStopHint() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "cursor-agent", snapshot: snap("Thinking...\nctrl+c to stop"))
        XCTAssertEqual(detection?.state, .working)
        XCTAssertTrue(detection?.visibleWorking ?? false)
    }

    func testCursorIdleFromPlaceholder() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "cursor-agent", snapshot: snap("Plan, search, build anything"))
        XCTAssertEqual(detection?.state, .idle)
    }

    func testCursorIdlePlaceholderNotBlockedDuringApproval() {
        // The idle placeholder must NOT win when an approval footer is present.
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = "Run this command?\nAllow once\nEnter to confirm • Esc to cancel"
        let detection = detector.detect(agentId: "cursor-agent", snapshot: snap(screen))
        XCTAssertEqual(detection?.state, .blocked)
    }

    // MARK: - copilot rules (BLOCKED only; WORKING/IDLE deliberately absent)

    func testCopilotBlockedOnToolApproval() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        Allow Copilot to run this command?
        1. Yes
        2. Yes, and approve git for the rest of the running session
        3. No, and tell Copilot what to do differently (Esc)
        """
        let detection = detector.detect(agentId: "copilot", snapshot: snap(screen))
        XCTAssertEqual(detection?.state, .blocked)
        XCTAssertTrue(detection?.visibleBlocker ?? false)
    }

    func testCopilotBenignOutputIsNotBlocked() {
        // A conservative manifest must not false-fire on ordinary output. With no
        // WORKING/IDLE rules (unverified for Copilot), a non-blocked screen falls
        // back to .idle — which never triggers a push. The contract we assert is
        // simply "not .blocked".
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "copilot", snapshot: snap("Here is the refactored function."))
        XCTAssertNotEqual(detection?.state, .blocked)
    }

    // MARK: - droid rules (BLOCKED only; command-approval prompt unverified, omitted)

    func testDroidBlockedOnMissionProposal() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        Mission proposal
        1. Proceed with the proposal
        2. Proceed with comment
        3. Manually edit mission
        4. No and explain why
        """
        let detection = detector.detect(agentId: "droid", snapshot: snap(screen))
        XCTAssertEqual(detection?.state, .blocked)
        XCTAssertTrue(detection?.visibleBlocker ?? false)
    }

    func testDroidBenignOutputIsNotBlocked() {
        // Bare "Autonomy: High" / ">" are too generic to match as blocked — the
        // manifest deliberately requires the specific mission/spec prompt tokens.
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "droid", snapshot: snap("Autonomy: High\n> analyze this codebase"))
        XCTAssertNotEqual(detection?.state, .blocked)
    }

    func testDroidNarrationProseIsNotBlocked() {
        // Regression: the spec-approval rule must anchor on the UI button label
        // "approve spec", NOT on conversational prose. An agent narrating
        // "I'll proceed with implementation…" while a persistent key-hint footer
        // shows "esc to cancel" must NOT be misread as a blocked approval prompt
        // (that would fire a spurious push).
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        I'll now proceed with implementation of the auth layer and run the tests.
        esc to cancel
        """
        let detection = detector.detect(agentId: "droid", snapshot: snap(screen))
        XCTAssertNotEqual(detection?.state, .blocked)
    }

    func testDroidBlockedOnSpecApproval() {
        // The genuine spec-approval screen (UI button + footer) still fires.
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        Spec ready for review.
        Approve Spec
        ↑↓ Navigate · Enter to select · Esc to cancel
        """
        let detection = detector.detect(agentId: "droid", snapshot: snap(screen))
        XCTAssertEqual(detection?.state, .blocked)
        XCTAssertTrue(detection?.visibleBlocker ?? false)
    }

    // MARK: - claude rules

    func testClaudeBlockedOnBashPermissionPrompt() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        Running a bash command
        Do you want to proceed?
        ❯ 1. Yes
          2. No
        """
        let detection = detector.detect(agentId: "claude", snapshot: snap(screen))
        XCTAssertEqual(detection?.state, .blocked)
        XCTAssertTrue(detection?.visibleBlocker ?? false)
    }

    func testClaudeWorkingFromOSCSpinnerTitle() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        // Braille spinner char U+2801 + space prefix in the title.
        let detection = detector.detect(agentId: "claude", snapshot: snap("", oscTitle: "\u{2801} building"))
        XCTAssertEqual(detection?.state, .working)
        XCTAssertTrue(detection?.visibleWorking ?? false)
    }

    func testClaudeWorkingFromInterruptFooter() {
        // Regression: Claude Code emits no braille-spinner title, and its
        // working status word is prefixed with ✳ (U+2733) — which collided with
        // the osc_title_idle rule, so a working session read as idle ("Waiting").
        // The screen_working_interrupt rule keys on the stable "esc to interrupt"
        // footer instead. Mirrors the real screenshot scenario.
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        ● The fix is a decisive success. Let me quantify.
        + Hullaballooing… (2m 27s · ↓ 6.0k tokens · thinking some more)
          esc to interrupt
        """
        let detection = detector.detect(agentId: "claude", snapshot: snap(screen, oscTitle: "✳ Hullaballooing"))
        XCTAssertEqual(detection?.state, .working)
        XCTAssertTrue(detection?.visibleWorking ?? false)
    }

    func testClaudeWorkingWhileThinkingWithPromptBoxBelow() {
        // Regression (real screenshot): while THINKING, Claude shows no
        // "esc to interrupt" footer — the spinner reads "… (27s · ↓ 1.5k tokens
        // · thinking)" — and the empty prompt box, status bar, and bypass line
        // sit BELOW it. So the interrupt-footer rule missed (no footer) and its
        // bottom_non_empty_lines(5) region never reached the spinner. Meanwhile
        // live_prompt_box matched the empty ❯ box → idle → sidebar "Waiting".
        // The spinner line itself is the authoritative working signal.
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        ● The claude-mem Stop hook is the prime suspect — it summarizes the session.
        · Symbioting… (27s · ↓ 1.5k tokens · thinking)
          Tip: Use /theme to change the color theme
        ────
        ❯
        ────
          bypass permissions on (shift+tab to cycle) · ← 1 agent
        """
        let detection = detector.detect(agentId: "claude", snapshot: snap(screen, oscTitle: "✳ Symbioting"))
        XCTAssertEqual(detection?.state, .working,
                       "a thinking spinner with a prompt box below it must read as working, not idle")
        XCTAssertTrue(detection?.visibleWorking ?? false)
    }

    func testClaudeWorkingSpinnerWithTokensAndInterrupt() {
        // The tool-execution variant: spinner + "esc to interrupt", prompt box
        // below. Same spinner signal drives it.
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        ● Running the build.
        · Cerebrating… (1m 4s · ↑ 2.3k tokens · esc to interrupt)
        ────
        ❯
        ────
        """
        let detection = detector.detect(agentId: "claude", snapshot: snap(screen, oscTitle: "✳ Cerebrating"))
        XCTAssertEqual(detection?.state, .working)
        XCTAssertTrue(detection?.visibleWorking ?? false)
    }

    func testClaudeWorkingEarlyThinkingBeforeTokens() {
        // In the first seconds of thinking the spinner has an elapsed timer but
        // no token count yet: "Pondering… (2s · thinking)". The spinner rule
        // anchors on the elapsed timer inside the parenthetical, so it still
        // reads as working.
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        ● Let me look into that.
        · Pondering… (2s · thinking)
        ────
        ❯
        ────
        """
        let detection = detector.detect(agentId: "claude", snapshot: snap(screen, oscTitle: "✳ Pondering"))
        XCTAssertEqual(detection?.state, .working)
    }

    func testClaudePermissionBeatsInterruptHint() {
        // A genuine permission prompt must still win over a lingering
        // "esc to interrupt" footer (priority + the rule's `not` guard).
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        Running a bash command
        Do you want to proceed?
        ❯ 1. Yes
          2. No
          esc to interrupt
        """
        let detection = detector.detect(agentId: "claude", snapshot: snap(screen))
        XCTAssertEqual(detection?.state, .blocked)
    }

    func testClaudeIdleFromPromptBox() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = """
        earlier output
        ────
        ❯
        ────
        """
        let detection = detector.detect(agentId: "claude", snapshot: snap(screen))
        XCTAssertEqual(detection?.state, .idle)
    }

    func testClaudeTranscriptViewerSkipsStateUpdate() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let screen = "showing detailed transcript\n↑↓ scroll"
        let detection = detector.detect(agentId: "claude", snapshot: snap(screen))
        XCTAssertTrue(detection?.skipStateUpdate ?? false)
    }

    func testClaudeFallbackIsIdleWhenNothingMatches() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "claude", snapshot: snap("just some plain output"))
        XCTAssertEqual(detection?.state, .idle)
        XCTAssertFalse(detection?.visibleIdle ?? true)
    }

    // MARK: - codex rules

    func testCodexBlockedFromOSCTitle() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "codex", snapshot: snap("", oscTitle: "Action Required"))
        XCTAssertEqual(detection?.state, .blocked)
    }

    func testCodexWorkingFromScreenFallback() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "codex", snapshot: snap("• Working (12s · esc to interrupt)"))
        XCTAssertEqual(detection?.state, .working)
    }

    // MARK: - opencode rules

    func testOpencodeBlockedOnPermissionRequired() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "opencode", snapshot: snap("△ Permission required"))
        XCTAssertEqual(detection?.state, .blocked)
    }

    func testOpencodeWorkingFromInterruptHint() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        let detection = detector.detect(agentId: "opencode", snapshot: snap("press esc to interrupt"))
        XCTAssertEqual(detection?.state, .working)
    }

    // MARK: - unknown agent

    func testUnknownAgentReturnsNil() {
        let detector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
        XCTAssertNil(detector.detect(agentId: "not-an-agent", snapshot: snap("x")))
    }

    // MARK: - priority tie-break

    func testHigherPriorityWins() {
        // A synthetic 2-rule manifest: both match, higher priority must win.
        let json = """
        {"id":"t","rules":[
          {"id":"low","state":"idle","priority":100,"region":"whole_recent","contains":["x"]},
          {"id":"high","state":"blocked","priority":900,"region":"whole_recent","contains":["x"]}
        ]}
        """
        let manifest = try! JSONDecoder().decode(AgentManifest.self, from: Data(json.utf8))
        let detector = AgentStateDetector(manifests: ["t": manifest])
        XCTAssertEqual(detector.detect(agentId: "t", snapshot: snap("x"))?.state, .blocked)
    }
}
