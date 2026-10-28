import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

@MainActor
final class ServerHubTests: XCTestCase {

    func testStartBuildsOneSlotPerEnabledBookmarkOnly() async {
        let a = makeConfig("a"), b = makeConfig("b", enabled: false), c = makeConfig("c")
        let h = HubHarness(configs: [a, b, c])
        await h.hub.start()
        XCTAssertNotNil(h.slot(a.id)); XCTAssertNil(h.slot(b.id)); XCTAssertNotNil(h.slot(c.id))
        XCTAssertEqual(h.slot(a.id)?.startCount, 1)
        XCTAssertEqual(h.hub.sections.map(\.id), [a.id, b.id, c.id], "sections follow bookmark order, disabled included")
        XCTAssertEqual(h.hub.sections[1].status, .disabled)
    }

    func testStartStaggersSlotStarts() async {
        let a = makeConfig("a"), b = makeConfig("b"), c = makeConfig("c")
        let h = HubHarness(configs: [a, b, c], stagger: .milliseconds(150))
        var order: [String] = []
        h.hub.onTestEvent = { order.append($0) }
        await h.hub.start()
        // sleep(0), start a, sleep(150ms), start b, sleep(300ms), start c — the
        // hub records the delays it requested, in order.
        XCTAssertEqual(h.hub.recordedSleeps, [.zero, .milliseconds(150), .milliseconds(300)])
        XCTAssertEqual(order.filter { $0.hasPrefix("start:") }, ["start:a", "start:b", "start:c"])
    }

    func testStatusDerivation() {
        typealias S = ServerSectionStatus
        XCTAssertEqual(S.derive(enabled: false, connection: .connected, isRecovering: false, isPerformingHandshake: false,
                                authRejected: false, recoveryFailed: false), .disabled)
        XCTAssertEqual(S.derive(enabled: true, connection: .connected, isRecovering: false, isPerformingHandshake: false,
                                authRejected: true, recoveryFailed: false), .authFailed("Token rejected by the relay"))
        XCTAssertEqual(S.derive(enabled: true, connection: .disconnected, isRecovering: true, isPerformingHandshake: false,
                                authRejected: false, recoveryFailed: false), .reconnecting)
        XCTAssertEqual(S.derive(enabled: true, connection: .connected, isRecovering: false, isPerformingHandshake: false,
                                authRejected: false, recoveryFailed: false), .live)
        XCTAssertEqual(S.derive(enabled: true, connection: .connected, isRecovering: false, isPerformingHandshake: true,
                                authRejected: false, recoveryFailed: false), .connecting)
        XCTAssertEqual(S.derive(enabled: true, connection: .connecting, isRecovering: false, isPerformingHandshake: false,
                                authRejected: false, recoveryFailed: false), .connecting)
        XCTAssertEqual(S.derive(enabled: true, connection: .disconnected, isRecovering: false, isPerformingHandshake: false,
                                authRejected: false, recoveryFailed: true), .offline)
        XCTAssertEqual(S.derive(enabled: true, connection: .disconnected, isRecovering: false, isPerformingHandshake: false,
                                authRejected: false, recoveryFailed: false), .offline)
    }

    func testOfflineSectionKeepsCachedRowsAndCountsNothing() async {
        let a = makeConfig("a")
        let h = HubHarness(configs: [a])
        await h.hub.start()
        let s1 = makeSession(agentState: .blocked)
        h.slot(a.id)!.goLive(with: [s1])
        await hubSettle()
        XCTAssertEqual(h.hub.sections[0].status, .live)
        XCTAssertEqual(h.hub.sections[0].sessions.map(\.id), [s1.id])
        XCTAssertFalse(h.hub.sections[0].isCached)
        XCTAssertEqual(h.hub.aggregate.liveServers, 1)

        h.slot(a.id)!.goOffline()
        h.slot(a.id)!.sessions = []     // a dropped socket empties the live list
        await hubSettle()
        XCTAssertEqual(h.hub.sections[0].status, .offline)
        XCTAssertEqual(h.hub.sections[0].sessions.map(\.id), [s1.id], "cached rows survive the drop (D4)")
        XCTAssertTrue(h.hub.sections[0].isCached)
        XCTAssertEqual(h.hub.aggregate.liveServers, 0)
    }

    func testFreshListReplacesCachedRowsAfterReconnect() async {
        let a = makeConfig("a")
        let h = HubHarness(configs: [a])
        await h.hub.start()
        let old = makeSession(), fresh = makeSession()
        h.slot(a.id)!.goLive(with: [old]); await hubSettle()
        h.slot(a.id)!.goOffline(); h.slot(a.id)!.sessions = []; await hubSettle()
        h.slot(a.id)!.goLive(with: [fresh]); await hubSettle()
        XCTAssertEqual(h.hub.sections[0].sessions.map(\.id), [fresh.id], "replaced, not merged (spec §5.3)")
    }

    func testMissingTokenBecomesAuthFailedSection() async {
        let a = makeConfig("a"), b = makeConfig("b")
        let h = HubHarness(configs: [a, b], tokensFor: [a.id])
        await h.hub.start()
        XCTAssertNotNil(h.slot(a.id))
        XCTAssertNil(h.slot(b.id), "no coordinator is built without a token")
        XCTAssertEqual(h.hub.sections[1].status, .authFailed("No token stored for this server"))
        XCTAssertEqual(h.hub.sections[1].sessions, [])
    }

    func testSetEnabledBuildsAndTearsDown() async {
        let a = makeConfig("a", enabled: false)
        let h = HubHarness(configs: [a])
        await h.hub.start()
        XCTAssertNil(h.slot(a.id))
        XCTAssertTrue(h.hub.setEnabled(a.id, true))
        await hubSettle()
        XCTAssertNotNil(h.slot(a.id))
        XCTAssertTrue(h.bookmarks.loadAll()[0].enabled, "persisted")
        let slot = h.slot(a.id)!
        XCTAssertTrue(h.hub.setEnabled(a.id, false))
        XCTAssertTrue(slot.tornDown)
        XCTAssertNil(h.slot(a.id))
        XCTAssertEqual(h.hub.sections[0].status, .disabled)
    }

    func testNinthEnabledIsRefused() async {
        let configs = (1...9).map { makeConfig("s\($0)", enabled: $0 <= 8) }
        let h = HubHarness(configs: configs)
        await h.hub.start()
        XCTAssertEqual(h.hub.enabledCount, 8)
        XCTAssertFalse(h.hub.setEnabled(configs[8].id, true), "cap is 8 (D12)")
        XCTAssertFalse(h.bookmarks.loadAll()[8].enabled)
        XCTAssertNotNil(h.hub.notice)
    }

    func testIdentityIsMirroredOntoTheBookmark() async {
        let a = makeConfig("a")
        let h = HubHarness(configs: [a])
        await h.hub.start()
        let identity = ServerIdentity(id: UUID(), name: "studio")
        h.slot(a.id)!.serverIdentity = identity
        await hubSettle()
        let saved = h.bookmarks.loadAll()[0]
        XCTAssertEqual(saved.instanceId, identity.id)
        XCTAssertEqual(saved.displayName, "studio")
        XCTAssertEqual(h.hub.sections[0].config.displayName, "studio")
    }

    func testStopTearsDownEverySlot() async {
        let a = makeConfig("a"), b = makeConfig("b")
        let h = HubHarness(configs: [a, b])
        await h.hub.start()
        let sa = h.slot(a.id)!, sb = h.slot(b.id)!
        h.hub.stop()
        XCTAssertTrue(sa.tornDown && sb.tornDown)
        XCTAssertNil(h.slot(a.id))
    }
}
