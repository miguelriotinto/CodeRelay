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
        XCTAssertNil(h.slot(a.id), "gone from the hub at once")
        await hubSettle()   // teardown follows the bounded push unregister (spec §10)
        XCTAssertTrue(slot.tornDown)
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

    // MARK: - Session-loss notices (session takeover spec §2, §3b, §6)

    private func liveLossHub(_ names: [String]) async -> (HubHarness, [ConnectionConfig]) {
        let configs = names.map { makeConfig($0) }
        let h = HubHarness(configs: configs)
        await h.hub.start()
        for c in configs { h.slot(c.id)!.goLive(with: [makeSession()]) }
        await hubSettle()
        return (h, configs)
    }

    func testFanOutWaitsForPassAlreadyInFlight() async {
        let (h, cfg) = await liveLossHub(["a"])
        let a = h.slot(cfg[0].id)!
        var alerts: [SessionLossAlert] = []
        let sub = h.hub.$takenAlert.compactMap { $0 }.sink { alerts.append($0) }
        defer { sub.cancel() }
        // Launch, scenePhase and network-restored inside ~100 ms: the trigger
        // returns at once because a handshake is already running; its result
        // lands later.
        a.passHangs = true
        let waitsBefore = a.passWaits                    // start() awaited the launch pass too
        let fg = Task { await h.hub.handleForegroundTransition(userInitiated: false) }
        await hubSettle()
        XCTAssertEqual(a.foregroundCount, 1)
        XCTAssertEqual(a.passWaits - waitsBefore, 1, "the hold awaits the pass, not just the trigger")
        a.reportLost(taken: [LostSession(id: UUID(), name: "api")])
        await hubSettle()
        XCTAssertTrue(alerts.isEmpty, "held while the in-flight pass runs")
        a.reportLost(taken: [LostSession(id: UUID(), name: "web")])
        a.releasePass()
        await fg.value
        await hubSettle()
        XCTAssertEqual(alerts.count, 1, "one alert for the whole fan-out")
        XCTAssertEqual(alerts.first?.title, "Sessions Moved")
        XCTAssertEqual(alerts.first?.message, "api and web were attached from another device.")
    }

    func testFanOutCapsAt10s() async {
        let (h, cfg) = await liveLossHub(["dead", "ok"])
        XCTAssertEqual(h.hub.fanOutBudget, .seconds(10), "the production cap is 10 s")
        h.hub.fanOutBudget = .milliseconds(300)          // scaled down for the test
        let dead = h.slot(cfg[0].id)!, ok = h.slot(cfg[1].id)!
        dead.foregroundHangs = true                       // never finishes
        ok.onForeground = { ok.reportLost(taken: [LostSession(id: UUID(), name: "api")]) }
        let fg = Task { await h.hub.handleForegroundTransition(userInitiated: false) }
        await hubSettle()
        XCTAssertEqual(ok.foregroundCount, 1)
        XCTAssertNil(h.hub.takenAlert, "held: the dead server's pass has not finished")
        try? await Task.sleep(for: .milliseconds(400))
        await hubSettle()
        XCTAssertEqual(h.hub.takenAlert?.message, "api was attached from another device.",
                       "the cap releases the other server's report")
        XCTAssertEqual(h.hub.takenAlert?.title, "Session Moved")
        dead.foregroundGate?.resume(); dead.foregroundGate = nil
        await fg.value
    }

    func testStealOnNonFocusedServerSurfaces() async {
        let (h, cfg) = await liveLossHub(["one", "two"])
        let one = h.slot(cfg[0].id)!, two = h.slot(cfg[1].id)!
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: one.sessions[0].id))
        await hubSettle()
        XCTAssertEqual(h.hub.focusServerId, cfg[0].id)
        two.reportLost(taken: [LostSession(id: two.sessions[0].id, name: "build")])
        await hubSettle()
        XCTAssertEqual(h.hub.takenAlert?.title, "Session Moved")
        XCTAssertEqual(h.hub.takenAlert?.message, "build was attached from another device.")
    }

    func testEndedGoesToNotice() async {
        let (h, cfg) = await liveLossHub(["a"])
        h.slot(cfg[0].id)!.reportLost(ended: [LostSession(id: UUID(), name: "api")])
        await hubSettle()
        XCTAssertEqual(h.hub.notice, "api ended while you were away.")
        XCTAssertNil(h.hub.takenAlert)
    }

    func testMultiServerBatchUsesDisplayNames() async {
        let a = ConnectionConfig(name: "a", host: "a.local", displayName: "Studio")
        let b = makeConfig("b")
        let h = HubHarness(configs: [a, b])
        await h.hub.start()
        h.hub.fanOutBudget = .seconds(5)
        h.slot(b.id)!.passHangs = true
        let fg = Task { await h.hub.handleForegroundTransition(userInitiated: false) }
        await hubSettle()
        h.slot(a.id)!.reportLost(taken: [LostSession(id: UUID(), name: "api")])
        h.slot(b.id)!.reportLost(taken: [LostSession(id: UUID(), name: "web")])
        h.slot(b.id)!.releasePass()
        await fg.value
        XCTAssertEqual(h.hub.takenAlert?.message, "api (on Studio) and web (on b) were attached from another device.")
    }

    func testEnableBuildsWithEnableReason() async {
        let a = makeConfig("a"), b = makeConfig("b", enabled: false)
        let h = HubHarness(configs: [a, b])
        await h.hub.start()
        XCTAssertEqual(h.slot(a.id)?.startReasons, [.launch], "launch announces")
        h.hub.setEnabled(b.id, true)
        await hubSettle()
        XCTAssertEqual(h.slot(b.id)?.startReasons, [.enable], "enabling a server is silent")
        h.hub.rebuildSlot(a.id)
        await hubSettle()
        XCTAssertEqual(h.slot(a.id)?.startReasons, [.enable], "a rebuilt slot is silent too")
    }
}
