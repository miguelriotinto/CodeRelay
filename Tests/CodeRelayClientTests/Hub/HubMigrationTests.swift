import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

@MainActor
final class HubMigrationTests: XCTestCase {

    private struct Env {
        let defaults: UserDefaults
        let bookmarks: SavedConnectionStore
        let state: HubStateStore
        let prefix = "mig.test"
        let device = "dev-1"
        let lastKey = "mig.test.lastServerId"
    }

    private func env(configs: [ConnectionConfig], lastServerId: String?) -> Env {
        let suite = "HubMigrationTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let bookmarks = SavedConnectionStore(key: "mig.bookmarks", defaults: d)
        bookmarks.saveAll(configs)
        if let lastServerId { d.set(lastServerId, forKey: "mig.test.lastServerId") }
        return Env(defaults: d, bookmarks: bookmarks, state: HubStateStore(keyPrefix: "mig.test", deviceId: "dev-1", defaults: d))
    }

    private func seedLegacy(_ e: Env, names: [UUID: String], active: UUID?) {
        let legacy = SessionOwnershipStore(keyPrefix: e.prefix, deviceId: e.device, defaults: e.defaults)
        legacy.saveNames(names)
        legacy.saveAgents([names.keys.first!: "claude"])
        legacy.saveActiveSession(active)
        legacy.saveCollapsedGroups(["/repo"])
    }

    private func run(_ e: Env) -> Bool {
        HubMigration.run(defaults: e.defaults, keyPrefix: e.prefix, deviceId: e.device,
                         bookmarks: e.bookmarks, lastServerIdKey: e.lastKey, stateStore: e.state)
    }

    func testLegacyStateMovesIntoTheLastServersNamespace() {
        let a = makeConfig("a"), b = makeConfig("b")
        let e = env(configs: [a, b], lastServerId: a.id.uuidString)
        let sid = UUID()
        seedLegacy(e, names: [sid: "alpha"], active: sid)

        XCTAssertTrue(run(e))

        let migrated = SessionOwnershipStore(keyPrefix: "\(e.prefix).\(a.id.uuidString)", deviceId: e.device, defaults: e.defaults)
        XCTAssertEqual(migrated.loadNames()[sid], "alpha")
        XCTAssertEqual(migrated.loadAgents()[sid], "claude")
        XCTAssertEqual(migrated.loadCollapsedGroups(), ["/repo"])
        XCTAssertEqual(e.state.loadActiveRef(), SessionRef(serverId: a.id, sessionId: sid))
        let saved = e.bookmarks.loadAll()
        XCTAssertTrue(saved[0].enabled, "the last-used server stays on (G8)")
        XCTAssertFalse(saved[1].enabled, "every other bookmark is off until the user enables it")
        // Legacy keys are gone.
        let legacy = SessionOwnershipStore(keyPrefix: e.prefix, deviceId: e.device, defaults: e.defaults)
        XCTAssertTrue(legacy.loadNames().isEmpty)
        XCTAssertNil(legacy.loadActiveSession())
        XCTAssertNil(e.defaults.object(forKey: e.lastKey), "lastServerId retired")
        XCTAssertTrue(e.state.isMigrated)
    }

    func testMigrationIsIdempotent() {
        let a = makeConfig("a")
        let e = env(configs: [a], lastServerId: a.id.uuidString)
        seedLegacy(e, names: [UUID(): "x"], active: nil)
        XCTAssertTrue(run(e))
        var disabled = e.bookmarks.loadAll()[0]
        disabled.enabled = false
        _ = e.bookmarks.add(disabled)
        XCTAssertFalse(run(e), "second run is a no-op")
        XCTAssertFalse(e.bookmarks.loadAll()[0].enabled, "a second run must not re-enable anything")
    }

    func testMigrationWithMissingLastServer() {
        let a = makeConfig("a"), b = makeConfig("b")
        let e = env(configs: [a, b], lastServerId: UUID().uuidString)   // deleted bookmark
        seedLegacy(e, names: [UUID(): "orphan"], active: nil)
        XCTAssertTrue(run(e))
        XCTAssertEqual(e.bookmarks.loadAll().map(\.enabled), [false, false])
        for c in [a, b] {
            let ns = SessionOwnershipStore(keyPrefix: "\(e.prefix).\(c.id.uuidString)", deviceId: e.device, defaults: e.defaults)
            XCTAssertTrue(ns.loadNames().isEmpty, "orphaned maps are dropped, not guessed onto a server")
        }
        XCTAssertNil(e.state.loadActiveRef())
    }

    func testSingleBookmarkIsEnabledEvenWithoutALastServer() {
        let a = makeConfig("a")
        let e = env(configs: [a], lastServerId: nil)
        XCTAssertTrue(run(e))
        XCTAssertTrue(e.bookmarks.loadAll()[0].enabled)
    }

    func testNoBookmarksStillMarksMigrated() {
        let e = env(configs: [], lastServerId: nil)
        XCTAssertTrue(run(e))
        XCTAssertTrue(e.state.isMigrated)
    }
}
