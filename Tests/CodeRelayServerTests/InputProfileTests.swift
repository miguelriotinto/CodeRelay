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

    func testBundledClaudeManifestCarriesClaudeCodeProfile() {
        let profile = AgentStateDetector.loadBundled()["claude"]?.input
        XCTAssertEqual(profile?.newline, [.ctrlEnter, .altEnter, .shiftEnter, .backslashEnter])
        XCTAssertEqual(profile?.submit, [.enter])
        XCTAssertEqual(profile?.killLineAcrossLines, true)
        XCTAssertEqual(profile?.inset, 4)
    }

    func testEveryBundledManifestStillLoads() {
        // A bad `input` block would make loadBundled() drop the manifest.
        let ids = Set(AgentStateDetector.loadBundled().keys)
        for expected in ["claude", "codex", "copilot", "cursor-agent", "droid", "opencode"] {
            XCTAssertTrue(ids.contains(expected), "\(expected) manifest failed to load")
        }
    }
}
