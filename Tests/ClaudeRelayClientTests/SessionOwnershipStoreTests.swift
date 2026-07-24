import XCTest
@testable import ClaudeRelayClient

/// Tests for `SessionOwnershipStore` — the diff-checked UserDefaults wrapper
/// that replaces the three inline `save*` helpers on `SharedSessionCoordinator`.
///
/// Each test uses an isolated `UserDefaults(suiteName:)` so the system defaults
/// database is never touched.
@MainActor
final class SessionOwnershipStoreTests: XCTestCase {

    /// Counts set(_:forKey:) calls so we can assert the diff-check actually
    /// prevents writes when nothing changed (C-21).
    final class CountingDefaults: UserDefaults, @unchecked Sendable {
        var writeCount = 0
        override func set(_ value: Any?, forKey defaultName: String) {
            writeCount += 1
            super.set(value, forKey: defaultName)
        }
    }

    private var defaults: CountingDefaults!

    override func setUp() async throws {
        let suite = "SessionOwnershipStoreTests-\(UUID().uuidString)"
        defaults = CountingDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults = nil
    }

    // MARK: - Key construction

    func testOwnershipKeyIsDeviceScoped() {
        let store = SessionOwnershipStore(keyPrefix: "com.clauderelay", deviceId: "DEV-123", defaults: defaults)
        XCTAssertEqual(store.namesKey, "com.clauderelay.sessionNames")
        XCTAssertEqual(store.ownedKey, "com.clauderelay.ownedSessions.DEV-123")
        XCTAssertEqual(store.agentsKey, "com.clauderelay.agentSessions")
    }

    func testDifferentDeviceIdsProduceDifferentOwnedKeys() {
        let storeA = SessionOwnershipStore(keyPrefix: "com.clauderelay", deviceId: "A", defaults: defaults)
        let storeB = SessionOwnershipStore(keyPrefix: "com.clauderelay", deviceId: "B", defaults: defaults)
        XCTAssertNotEqual(storeA.ownedKey, storeB.ownedKey)
    }

    // MARK: - Diff-checked writes

    func testSaveNamesWritesOnceThenDiffChecks() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "d", defaults: defaults)
        let before = defaults.writeCount

        let names = [UUID(): "Alice", UUID(): "Bob"]
        XCTAssertTrue(store.saveNames(names))
        let afterFirst = defaults.writeCount
        XCTAssertEqual(afterFirst, before + 1, "First save must write")

        // Saving the identical dictionary must be a no-op.
        XCTAssertFalse(store.saveNames(names))
        let afterSecond = defaults.writeCount
        XCTAssertEqual(afterSecond, afterFirst, "Second identical save must not write")
    }

    func testSaveOwnedDiffChecks() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "d", defaults: defaults)
        let owned: Set<UUID> = [UUID(), UUID()]
        XCTAssertTrue(store.saveOwned(owned))
        let afterFirst = defaults.writeCount
        XCTAssertFalse(store.saveOwned(owned))
        XCTAssertEqual(defaults.writeCount, afterFirst)
    }

    func testSaveAgentsDiffChecks() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "d", defaults: defaults)
        let agents: [UUID: String] = [UUID(): "claude", UUID(): "codex"]
        XCTAssertTrue(store.saveAgents(agents))
        let afterFirst = defaults.writeCount
        XCTAssertFalse(store.saveAgents(agents))
        XCTAssertEqual(defaults.writeCount, afterFirst)
    }

    func testSaveNamesWritesAgainAfterMutation() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "d", defaults: defaults)
        var names = [UUID(): "Alice"]
        XCTAssertTrue(store.saveNames(names))
        names[UUID()] = "Bob"
        XCTAssertTrue(store.saveNames(names), "Changed dictionary must write")
    }

    // MARK: - Load round-trip

    func testNamesRoundTrip() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "d", defaults: defaults)
        let id = UUID()
        XCTAssertTrue(store.saveNames([id: "Rhaegar"]))
        let loaded = SessionOwnershipStore(keyPrefix: "p", deviceId: "d", defaults: defaults).loadNames()
        XCTAssertEqual(loaded[id], "Rhaegar")
    }

    func testOwnedRoundTrip() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "d", defaults: defaults)
        let ids: Set<UUID> = [UUID(), UUID()]
        XCTAssertTrue(store.saveOwned(ids))
        let loaded = SessionOwnershipStore(keyPrefix: "p", deviceId: "d", defaults: defaults).loadOwned()
        XCTAssertEqual(loaded, ids)
    }

    func testAgentsRoundTrip() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "d", defaults: defaults)
        let id = UUID()
        XCTAssertTrue(store.saveAgents([id: "claude"]))
        let loaded = SessionOwnershipStore(keyPrefix: "p", deviceId: "d", defaults: defaults).loadAgents()
        XCTAssertEqual(loaded[id], "claude")
    }

    // MARK: - Prune

    func testPruneRemovesOnlyStale() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "d", defaults: defaults)
        let keep = UUID(), drop = UUID()
        var names: [UUID: String] = [keep: "Tyrion", drop: "Sansa"]
        var owned: Set<UUID> = [keep, drop]
        var agents: [UUID: String] = [keep: "claude", drop: "codex"]
        _ = store.saveNames(names); _ = store.saveOwned(owned); _ = store.saveAgents(agents)

        let result = store.pruneToServerSessions(
            serverIds: [keep], names: &names, owned: &owned, agents: &agents
        )

        XCTAssertEqual(names, [keep: "Tyrion"])
        XCTAssertEqual(owned, [keep])
        XCTAssertEqual(agents, [keep: "claude"])
        XCTAssertEqual(result.removedNames, [drop])
        XCTAssertEqual(result.removedOwned, [drop])
        XCTAssertEqual(result.removedAgents, [drop])
    }

    func testPruneWithNoStaleIsFullyNoop() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "d", defaults: defaults)
        let id = UUID()
        var names: [UUID: String] = [id: "Only"]
        var owned: Set<UUID> = [id]
        var agents: [UUID: String] = [id: "claude"]
        _ = store.saveNames(names); _ = store.saveOwned(owned); _ = store.saveAgents(agents)
        let writesBefore = defaults.writeCount

        let result = store.pruneToServerSessions(
            serverIds: [id], names: &names, owned: &owned, agents: &agents
        )

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(defaults.writeCount, writesBefore, "No-op prune must not touch UserDefaults")
    }

    // MARK: - F3 layout persistence

    func testLayoutKeysAreDeviceScoped() {
        let store = SessionOwnershipStore(keyPrefix: "com.clauderelay", deviceId: "DEV-123", defaults: defaults)
        XCTAssertEqual(store.activeSessionKey, "com.clauderelay.activeSession.DEV-123")
        XCTAssertEqual(store.collapsedGroupsKey, "com.clauderelay.collapsedGroups.DEV-123")
        let other = SessionOwnershipStore(keyPrefix: "com.clauderelay", deviceId: "OTHER", defaults: defaults)
        XCTAssertNotEqual(store.activeSessionKey, other.activeSessionKey,
                          "one device's focus must not overwrite another's")
    }

    func testActiveSessionRoundTrips() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "D", defaults: defaults)
        let id = UUID()
        XCTAssertTrue(store.saveActiveSession(id))
        // A fresh store reading the same defaults sees the persisted value.
        let reopened = SessionOwnershipStore(keyPrefix: "p", deviceId: "D", defaults: defaults)
        XCTAssertEqual(reopened.loadActiveSession(), id)
    }

    func testActiveSessionSaveIsDiffChecked() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "D", defaults: defaults)
        let id = UUID()
        XCTAssertTrue(store.saveActiveSession(id))
        let writes = defaults.writeCount
        XCTAssertFalse(store.saveActiveSession(id), "re-saving the same id must no-op")
        XCTAssertEqual(defaults.writeCount, writes)
    }

    func testActiveSessionClearsWithNil() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "D", defaults: defaults)
        let id = UUID()
        store.saveActiveSession(id)
        XCTAssertTrue(store.saveActiveSession(nil))
        XCTAssertNil(store.loadActiveSession())
    }

    func testPruneClearsActiveSessionNoLongerOnServer() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "D", defaults: defaults)
        let active = UUID()
        let survivor = UUID()
        store.saveActiveSession(active)
        var names: [UUID: String] = [:]; var owned: Set<UUID> = []; var agents: [UUID: String] = [:]
        // `active` is not in serverIds → prune must clear it so we don't restore a dead tab.
        _ = store.pruneToServerSessions(serverIds: [survivor], names: &names, owned: &owned, agents: &agents)
        XCTAssertNil(store.loadActiveSession())
    }

    func testPrunePreservesActiveSessionStillOnServer() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "D", defaults: defaults)
        let active = UUID()
        store.saveActiveSession(active)
        var names: [UUID: String] = [:]; var owned: Set<UUID> = []; var agents: [UUID: String] = [:]
        _ = store.pruneToServerSessions(serverIds: [active], names: &names, owned: &owned, agents: &agents)
        XCTAssertEqual(store.loadActiveSession(), active)
    }

    func testCollapsedGroupsRoundTrip() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "D", defaults: defaults)
        XCTAssertTrue(store.saveCollapsedGroups(["/repo/a", "/repo/b"]))
        let reopened = SessionOwnershipStore(keyPrefix: "p", deviceId: "D", defaults: defaults)
        XCTAssertEqual(reopened.loadCollapsedGroups(), ["/repo/a", "/repo/b"])
    }

    func testCollapsedGroupsSaveIsDiffChecked() {
        let store = SessionOwnershipStore(keyPrefix: "p", deviceId: "D", defaults: defaults)
        _ = store.saveCollapsedGroups(["x"])
        let writes = defaults.writeCount
        XCTAssertFalse(store.saveCollapsedGroups(["x"]), "re-saving the same set must no-op")
        XCTAssertEqual(defaults.writeCount, writes)
    }
}
