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

    func testMergeAddsAllFourEventsToEmptySettings() {
        let (settings, added) = HookSettingsMerger.merge(into: [:], hookPath: path)
        XCTAssertEqual(Set(added), Set(HookSettingsMerger.events))
        for event in HookSettingsMerger.events {
            let cmds = commands(settings, event: event)
            XCTAssertEqual(cmds.count, 1, "\(event) should have one command")
            XCTAssertTrue(cmds[0].contains(path), cmds[0])
            XCTAssertTrue(cmds[0].hasSuffix(event), "the hook takes the event name as argv[1]: \(cmds[0])")
        }
    }

    func testMergeIsIdempotent() {
        let (once, _) = HookSettingsMerger.merge(into: [:], hookPath: path)
        let (twice, added) = HookSettingsMerger.merge(into: once, hookPath: path)
        XCTAssertTrue(added.isEmpty, "re-running should add nothing")
        for event in HookSettingsMerger.events {
            XCTAssertEqual(commands(twice, event: event).count, 1, "\(event) must not be duplicated")
        }
    }

    func testMergePreservesUnrelatedHooks() {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/my-own-hook"]]]]
            ],
            "theme": "dark"
        ]
        let (settings, added) = HookSettingsMerger.merge(into: existing, hookPath: path)
        XCTAssertEqual(settings["theme"] as? String, "dark", "unrelated keys must survive")
        let stopCommands = commands(settings, event: "Stop")
        XCTAssertTrue(stopCommands.contains("/usr/local/bin/my-own-hook"), "existing hook must survive")
        XCTAssertTrue(stopCommands.contains { $0.contains(path) }, "ours must be added alongside")
        XCTAssertTrue(added.contains("Stop"))
    }

    func testRemoveDropsOnlyOurEntries() {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/my-own-hook"]]]]
            ]
        ]
        let (installed, _) = HookSettingsMerger.merge(into: existing, hookPath: path)
        let (removed, events) = HookSettingsMerger.remove(from: installed, hookPath: path)
        XCTAssertTrue(events.contains("Stop"))
        let stopCommands = commands(removed, event: "Stop")
        XCTAssertEqual(stopCommands, ["/usr/local/bin/my-own-hook"], "only ours should go")
    }

    func testRemoveOnCleanSettingsIsANoOp() {
        let (settings, removed) = HookSettingsMerger.remove(from: [:], hookPath: path)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue((settings["hooks"] as? [String: Any] ?? [:]).isEmpty)
    }
}
