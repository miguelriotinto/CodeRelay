import XCTest
@testable import ClaudeRelayCLI

final class HookSettingsMergeTests: XCTestCase {

    private let path = "~/.claude-relay/hooks/claude-relay-state-hook.sh"

    private func commands(_ settings: [String: Any], event: String) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any],
              let entries = hooks[event] as? [[String: Any]] else { return [] }
        return entries.flatMap { entry -> [String] in
            (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
        }
    }

    func testMergeAddsAllFourEventsToEmptySettings() throws {
        let (settings, added) = try HookSettingsMerger.merge(into: [:], hookPath: path)
        XCTAssertEqual(Set(added), Set(HookSettingsMerger.events))
        for event in HookSettingsMerger.events {
            let cmds = commands(settings, event: event)
            XCTAssertEqual(cmds.count, 1, "\(event) should have one command")
            XCTAssertTrue(cmds[0].contains(path), cmds[0])
            XCTAssertTrue(cmds[0].hasSuffix(event), "the hook takes the event name as argv[1]: \(cmds[0])")
        }
    }

    func testMergeIsIdempotent() throws {
        let (once, _) = try HookSettingsMerger.merge(into: [:], hookPath: path)
        let (twice, added) = try HookSettingsMerger.merge(into: once, hookPath: path)
        XCTAssertTrue(added.isEmpty, "re-running should add nothing")
        for event in HookSettingsMerger.events {
            XCTAssertEqual(commands(twice, event: event).count, 1, "\(event) must not be duplicated")
        }
    }

    func testMergePreservesUnrelatedHooks() throws {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/my-own-hook"]]]]
            ],
            "theme": "dark"
        ]
        let (settings, added) = try HookSettingsMerger.merge(into: existing, hookPath: path)
        XCTAssertEqual(settings["theme"] as? String, "dark", "unrelated keys must survive")
        let stopCommands = commands(settings, event: "Stop")
        XCTAssertTrue(stopCommands.contains("/usr/local/bin/my-own-hook"), "existing hook must survive")
        XCTAssertTrue(stopCommands.contains { $0.contains(path) }, "ours must be added alongside")
        XCTAssertTrue(added.contains("Stop"))
    }

    func testRemoveDropsOnlyOurEntries() throws {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/my-own-hook"]]]]
            ]
        ]
        let (installed, _) = try HookSettingsMerger.merge(into: existing, hookPath: path)
        let (removed, events) = try HookSettingsMerger.remove(from: installed, hookPath: path)
        XCTAssertTrue(events.contains("Stop"))
        let stopCommands = commands(removed, event: "Stop")
        XCTAssertEqual(stopCommands, ["/usr/local/bin/my-own-hook"], "only ours should go")
    }

    func testRemoveOnCleanSettingsIsANoOp() throws {
        let (settings, removed) = try HookSettingsMerger.remove(from: [:], hookPath: path)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue((settings["hooks"] as? [String: Any] ?? [:]).isEmpty)
    }

    func testMergeRefusesWhenHooksIsAnArray() {
        let corrupt: [String: Any] = ["hooks": ["array", "not", "dictionary"]]
        XCTAssertThrowsError(try HookSettingsMerger.merge(into: corrupt, hookPath: path)) { error in
            guard let hookError = error as? HookSettingsError else {
                XCTFail("expected HookSettingsError, got \(error)")
                return
            }
            if case .hooksIsNotDictionary = hookError {
                // correct
            } else {
                XCTFail("expected hooksIsNotDictionary, got \(hookError)")
            }
        }
    }

    func testMergeRefusesWhenEventIsAString() {
        let corrupt: [String: Any] = ["hooks": ["Stop": "not an array"]]
        XCTAssertThrowsError(try HookSettingsMerger.merge(into: corrupt, hookPath: path)) { error in
            guard let hookError = error as? HookSettingsError else {
                XCTFail("expected HookSettingsError, got \(error)")
                return
            }
            if case .eventIsNotArray(let event, _) = hookError {
                XCTAssertEqual(event, "Stop")
            } else {
                XCTFail("expected eventIsNotArray, got \(hookError)")
            }
        }
    }

    func testMergeAcceptsAbsentKeys() throws {
        let (settings, added) = try HookSettingsMerger.merge(into: [:], hookPath: path)
        XCTAssertEqual(Set(added), Set(HookSettingsMerger.events))
        XCTAssertNotNil(settings["hooks"])
    }

    func testMergePreservesUnrelatedEventsAcrossValidationPath() throws {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/my-own-hook"]]]],
                "PreToolUse": [["hooks": [["type": "command", "command": "/other-hook"]]]]
            ]
        ]
        let (settings, added) = try HookSettingsMerger.merge(into: existing, hookPath: path)
        let stopCommands = commands(settings, event: "Stop")
        XCTAssertTrue(stopCommands.contains("/usr/local/bin/my-own-hook"), "existing hook must survive")
        let preToolCommands = commands(settings, event: "PreToolUse")
        XCTAssertTrue(preToolCommands.contains("/other-hook"), "unrelated event must survive")
        XCTAssertTrue(added.contains("Stop"))
        XCTAssertTrue(added.contains("PreToolUse"))
    }

    func testMergeIsIdempotentAfterValidation() throws {
        let (once, _) = try HookSettingsMerger.merge(into: [:], hookPath: path)
        let (twice, added) = try HookSettingsMerger.merge(into: once, hookPath: path)
        XCTAssertTrue(added.isEmpty, "re-running should add nothing")
        for event in HookSettingsMerger.events {
            XCTAssertEqual(commands(twice, event: event).count, 1, "\(event) must not be duplicated")
        }
    }

    func testRemoveRefusesWhenHooksIsNotADictionary() {
        let corrupt: [String: Any] = ["hooks": "string"]
        XCTAssertThrowsError(try HookSettingsMerger.remove(from: corrupt, hookPath: path)) { error in
            guard let hookError = error as? HookSettingsError else {
                XCTFail("expected HookSettingsError, got \(error)")
                return
            }
            if case .hooksIsNotDictionary = hookError {
                // correct
            } else {
                XCTFail("expected hooksIsNotDictionary, got \(hookError)")
            }
        }
    }

    func testRemoveRefusesWhenEventIsAnArrayOfStrings() {
        let corrupt: [String: Any] = ["hooks": ["Stop": ["string1", "string2"]]]
        XCTAssertThrowsError(try HookSettingsMerger.remove(from: corrupt, hookPath: path)) { error in
            guard let hookError = error as? HookSettingsError else {
                XCTFail("expected HookSettingsError, got \(error)")
                return
            }
            if case .eventIsNotArray = hookError {
                // correct
            } else {
                XCTFail("expected eventIsNotArray, got \(hookError)")
            }
        }
    }
}
