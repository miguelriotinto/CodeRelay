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
