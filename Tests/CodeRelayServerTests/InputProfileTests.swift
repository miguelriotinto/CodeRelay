import XCTest
@testable import CodeRelayServer

final class InputProfileTests: XCTestCase {
    private func decodeProfile(_ json: String) throws -> InputProfile {
        try JSONDecoder().decode(InputProfile.self, from: Data(json.utf8))
    }

    func testDefaultsAreShellLike() {
        let p = InputProfile.default
        XCTAssertEqual(p.newline, [])
        XCTAssertEqual(p.submit, [.enter, .ctrlEnter])
        XCTAssertFalse(p.killLineAcrossLines)
        XCTAssertEqual(p.inset, 0)
        XCTAssertNil(p.probedWith)
    }

    func testEmptyObjectDecodesToDefaults() throws {
        XCTAssertEqual(try decodeProfile("{}"), .default)
    }

    func testFullObjectDecodes() throws {
        let p = try decodeProfile("""
        {"newline": ["ctrl_enter", "backslash_enter"], "submit": ["enter"],
         "killLineAcrossLines": true, "inset": 4, "probedWith": "claude 2.1.0"}
        """)
        XCTAssertEqual(p.newline, [.ctrlEnter, .backslashEnter])
        XCTAssertEqual(p.submit, [.enter])
        XCTAssertTrue(p.killLineAcrossLines)
        XCTAssertEqual(p.inset, 4)
        XCTAssertEqual(p.probedWith, "claude 2.1.0")
    }

    func testUnknownSymbolIsRejected() {
        XCTAssertThrowsError(try decodeProfile(#"{"newline": ["bogus_enter"]}"#))
    }

    func testNegativeInsetIsRejected() {
        XCTAssertThrowsError(try decodeProfile(#"{"inset": -1}"#))
    }

    func testForEnterMapsSingleModifiers() {
        XCTAssertEqual(InputKey.forEnter([]), .enter)
        XCTAssertEqual(InputKey.forEnter([.control]), .ctrlEnter)
        XCTAssertEqual(InputKey.forEnter([.alt]), .altEnter)
        XCTAssertEqual(InputKey.forEnter([.shift]), .shiftEnter)
        XCTAssertNil(InputKey.forEnter([.control, .alt]))
        XCTAssertNil(InputKey.forEnter([.super]))
    }

    func testManifestWithoutInputDecodesNil() throws {
        let manifest = try JSONDecoder().decode(
            AgentManifest.self, from: Data(#"{"id": "x", "rules": []}"#.utf8))
        XCTAssertNil(manifest.input)
    }

    func testDetectorReturnsManifestProfileOrDefault() throws {
        let manifest = try JSONDecoder().decode(AgentManifest.self, from: Data("""
        {"id": "x", "rules": [], "input": {"newline": ["shift_enter"], "submit": ["enter"]}}
        """.utf8))
        let detector = AgentStateDetector(manifests: ["x": manifest])
        XCTAssertEqual(detector.inputProfile(for: "x").newline, [.shiftEnter])
        XCTAssertEqual(detector.inputProfile(for: "nope"), .default)
    }

    /// The manifest values every probed agent ships with. These are measurements
    /// (`AgentInputProfileProbeTests`, 2026-09-13), not preferences — a change
    /// here means the agent's input box changed or the probe was re-read wrong.
    /// `ctrl_enter` is absent from BOTH lists on purpose: `CSI 13;5u` measured as
    /// "no effect" on both agents, so the tracker clears on it.
    func testBundledProbedManifestsCarryTheirMeasuredProfiles() {
        let expected: [(id: String, inset: Int)] = [("claude", 4), ("codex", 3)]
        let bundled = AgentStateDetector.loadBundled()
        for (id, inset) in expected {
            guard let profile = bundled[id]?.input else {
                XCTFail("\(id) manifest has no input block")
                continue
            }
            XCTAssertEqual(profile.newline, [.shiftEnter, .altEnter, .backslashEnter, .ctrlJ], id)
            XCTAssertEqual(profile.submit, [.enter], id)
            XCTAssertEqual(profile.killLineAcrossLines, true, id)
            XCTAssertEqual(profile.inset, inset, id)
            XCTAssertNotNil(profile.probedWith, id)
        }
    }

    /// The manifest spelling is wire format: a rename silently disables the
    /// newline chord on every shipped agent.
    func testCtrlJSymbolSpelling() {
        XCTAssertEqual(InputKey(rawValue: "ctrl_j"), .ctrlJ)
        XCTAssertEqual(InputKey.ctrlJ.rawValue, "ctrl_j")
        // `forEnter` never produces it — `KeyEvent.lineFeed` maps to it directly.
        XCTAssertNotEqual(InputKey.forEnter([.control]), .ctrlJ)
    }

    func testMalformedInputBlockKeepsTheRules() throws {
        let manifest = try JSONDecoder().decode(AgentManifest.self, from: Data("""
        {"id": "x",
         "rules": [{"id": "r", "state": "idle", "priority": 1, "region": "whole_recent",
                    "contains": ["hi"]}],
         "input": {"newline": ["not_a_key"]}}
        """.utf8))
        XCTAssertNil(manifest.input)          // degrades to the plain-shell profile
        XCTAssertEqual(manifest.rules.count, 1)
        XCTAssertEqual(manifest.rules.first?.id, "r")
    }

    /// Review A-4: a manifest under `~/.claude-relay/agents/` is user free text,
    /// so its `id` reaches the log with whatever the file said. A `\n` in it forges
    /// a log line; an unbounded one floods `/logs`, which is readable over the
    /// admin API. Sanitised on the pairing-label rule: control characters and
    /// newlines stripped, 60 scalars.
    func testMalformedInputBlockLogsASanitisedId() throws {
        let hostileId = "a\u{001B}[2Jb\nFORGED [ERROR] [detection] relay compromised"
            + String(repeating: "z", count: 80)
        let json = try JSONSerialization.data(withJSONObject: [
            "id": hostileId,
            "rules": [],
            "input": ["newline": ["not_a_key"]],
        ])
        let manifest = try JSONDecoder().decode(AgentManifest.self, from: json)
        XCTAssertNil(manifest.input)
        XCTAssertEqual(manifest.id, hostileId, "only the *log* is sanitised, not the id itself")

        let recent = RelayLogger.store.recent(count: 2_000)
        let line = recent.last { $0.contains("invalid \"input\" block ignored") }
        XCTAssertNotNil(line, "the malformed input block must still be logged")
        XCTAssertFalse(line?.contains("\u{001B}") == true, "an escape sequence reached the log")
        XCTAssertFalse(line?.contains("\n") == true, "the newline survived, so the tail is a forged log line")
        XCTAssertFalse(line?.contains(String(repeating: "z", count: 61)) == true,
                       "the id was not capped at 60 scalars")
        XCTAssertEqual(AgentManifest.sanitizedForLog(hostileId).unicodeScalars.count, 60)
    }

    func testEveryBundledManifestStillLoads() {
        // A bad *rules* block would make loadBundled() drop the manifest; a bad
        // `input` block only costs the input profile (see the test above).
        let ids = Set(AgentStateDetector.loadBundled().keys)
        for expected in ["claude", "codex", "copilot", "cursor-agent", "droid", "opencode"] {
            XCTAssertTrue(ids.contains(expected), "\(expected) manifest failed to load")
        }
    }
}
