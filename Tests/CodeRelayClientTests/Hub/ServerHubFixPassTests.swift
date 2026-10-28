import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

/// Fix pass after the whole-branch review: the single-attachment invariant
/// under overlapping selections, the hub mirroring a coordinator's own
/// attach/detach, concurrent (not serial) start and fan-out, and the
/// management rules (cap on reload, push unregister on disable, rebuild).
@MainActor
final class ServerHubFixPassTests: XCTestCase {

    private func liveHub(_ names: [String], maxEnabled: Int = 8) async -> (HubHarness, [ConnectionConfig]) {
        let configs = names.map { makeConfig($0) }
        let h = HubHarness(configs: configs, maxEnabled: maxEnabled)
        await h.hub.start()
        for c in configs { h.slot(c.id)!.goLive(with: [makeSession(), makeSession()]) }
        await hubSettle()
        return (h, configs)
    }

    private func bounded<T>(_ budget: Duration, _ op: @escaping @MainActor () async -> T) async -> T? {
        var result: T?
        await BoundedWait.run(budget: budget) { result = await op() }
        return result
    }

    // MARK: - D9 under overlapping selections (review C1)

    func testOverlappingSelectsLeaveExactlyTheLastOneAttached() async {
        let (h, cfg) = await liveHub(["a", "b"])
        let a = h.slot(cfg[0].id)!, b = h.slot(cfg[1].id)!
        let sa = a.sessions[0].id, sb1 = b.sessions[0].id, sb2 = b.sessions[1].id
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: sa))
        a.detachHangs = true
        h.hub.detachBudget = .seconds(5)
        let first = Task { await h.hub.select(SessionRef(serverId: cfg[1].id, sessionId: sb1)) }
        await hubSettle()                                   // first is parked in detachBounded(a)
        a.detachHangs = false
        await h.hub.select(SessionRef(serverId: cfg[1].id, sessionId: sb2))
        a.detachGate?.resume(); a.detachGate = nil
        await first.value
        XCTAssertEqual(h.hub.activeRef, SessionRef(serverId: cfg[1].id, sessionId: sb2))
        XCTAssertEqual(b.switchedTo, [sb2], "the stale first select must not re-attach sb1 after sb2 won")
        XCTAssertEqual(b.activeSessionId, sb2)
    }

    func testStaleCrossServerSelectDoesNotAttachOnTheAbandonedServer() async {
        let (h, cfg) = await liveHub(["a", "b", "c"])
        let a = h.slot(cfg[0].id)!, b = h.slot(cfg[1].id)!, c = h.slot(cfg[2].id)!
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: a.sessions[0].id))
        a.detachHangs = true
        h.hub.detachBudget = .seconds(5)
        let first = Task { await h.hub.select(SessionRef(serverId: cfg[1].id, sessionId: b.sessions[0].id)) }
        await hubSettle()
        a.detachHangs = false
        await h.hub.select(SessionRef(serverId: cfg[2].id, sessionId: c.sessions[0].id))
        a.detachGate?.resume(); a.detachGate = nil
        await first.value
        XCTAssertNil(b.activeSessionId, "b was abandoned before its attach ran")
        XCTAssertEqual(b.switchedTo, [])
        XCTAssertEqual(c.activeSessionId, c.sessions[0].id)
        XCTAssertEqual(h.hub.activeRef?.serverId, cfg[2].id)
    }

    // MARK: - Pending selection is one ref, equal to activeRef (review C2)

    func testAbandonedPendingSelectionIsNotAppliedWhenTheServerReturns() async {
        let (h, cfg) = await liveHub(["a", "b"])
        let a = h.slot(cfg[0].id)!, b = h.slot(cfg[1].id)!
        let sa = a.sessions[0].id, sb = b.sessions[0].id
        a.goOffline(); await hubSettle()
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: sa))   // pending on offline a
        await h.hub.select(SessionRef(serverId: cfg[1].id, sessionId: sb))   // the user moves on
        a.goLive(with: a.sessions); await hubSettle()
        XCTAssertEqual(a.switchedTo, [], "an abandoned pending selection must never attach")
        XCTAssertNil(a.activeSessionId)
        XCTAssertEqual(h.hub.activeRef, SessionRef(serverId: cfg[1].id, sessionId: sb))
        XCTAssertEqual(b.activeSessionId, sb)
    }

    func testDeepLinkEnableDetachesTheCurrentServerFirst() async {
        let a = makeConfig("a"); var b = makeConfig("b", enabled: false)
        let identity = UUID(); b.instanceId = identity
        let h = HubHarness(configs: [a, b])
        await h.hub.start()
        let slotA = h.slot(a.id)!; slotA.goLive(with: [makeSession()]); await hubSettle()
        await h.hub.select(SessionRef(serverId: a.id, sessionId: slotA.sessions[0].id))
        let target = UUID()
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: target, serverInstanceId: identity))
        XCTAssertEqual(outcome, .enabledAndSelected(SessionRef(serverId: b.id, sessionId: target)))
        XCTAssertEqual(slotA.detachActiveCount, 1, "one attachment: a is detached before b is enabled")
        XCTAssertNil(slotA.activeSessionId)
    }

    func testDeepLinkPrefersTheEnabledDuplicateBookmark() async {
        let identity = UUID()
        var a = makeConfig("a"); a.instanceId = identity
        var b = makeConfig("b", enabled: false); b.instanceId = identity
        let h = HubHarness(configs: [b, a])                 // the disabled twin is listed first
        await h.hub.start()
        let s = makeSession(); h.slot(a.id)!.goLive(with: [s]); await hubSettle()
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: s.id, serverInstanceId: identity))
        XCTAssertEqual(outcome, .selected(SessionRef(serverId: a.id, sessionId: s.id)))
        XCTAssertFalse(h.bookmarks.loadAll().first { $0.id == b.id }!.enabled, "no second socket to the same relay")
    }

    // MARK: - The hub mirrors a coordinator's own attach/detach (review I3 / Mac C1)

    func testActiveRefFollowsACoordinatorThatDetachedOnItsOwn() async {
        let (h, cfg) = await liveHub(["a"])
        let a = h.slot(cfg[0].id)!; let s = a.sessions[0].id
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: s))
        a.activeSessionId = nil                              // ⌘W / terminate / stolen, inside the coordinator
        await hubSettle()
        XCTAssertNil(h.hub.activeRef, "the hub mirrors the coordinator's own detach")
        XCTAssertNil(h.state.loadActiveRef())
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: s))
        XCTAssertEqual(a.switchedTo, [s, s], "re-selecting the detached row attaches again")
    }

    func testActiveRefAdoptsASessionTheCoordinatorAttachedOnItsOwn() async {
        let (h, cfg) = await liveHub(["a"])
        let remote = UUID()
        await h.slot(cfg[0].id)!.attachRemoteSession(id: remote, serverName: nil)   // Attach sheet / QR
        await hubSettle()
        XCTAssertEqual(h.hub.activeRef, SessionRef(serverId: cfg[0].id, sessionId: remote))
        XCTAssertEqual(h.state.loadActiveRef(), h.hub.activeRef)
    }

    func testAFailedSwitchLeavesNoStaleHighlight() async {
        let (h, cfg) = await liveHub(["a"])
        let a = h.slot(cfg[0].id)!; a.switchFails = true
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: a.sessions[0].id))
        await hubSettle()
        XCTAssertNil(h.hub.activeRef, "the coordinator never attached, so nothing is selected")
    }

    // MARK: - Concurrent start and fan-out (review I1 / Mac I9)

    func testASlowServerStartDoesNotDelayTheOthers() async {
        let configs = [makeConfig("slow"), makeConfig("fast")]
        let h = HubHarness(configs: configs)
        h.startHangs = [configs[0].id]
        let started = Task { await h.hub.start() }
        await hubSettle()
        XCTAssertEqual(h.slot(configs[1].id)?.startCount, 1, "fast was built while slow is still handshaking")
        h.releaseStart(configs[0].id)
        await started.value
        XCTAssertEqual(h.hub.recordedSleeps, [.zero, .milliseconds(150)], "the stagger is kept")
    }

    func testForegroundFanOutDoesNotSerializeBehindASlowServer() async {
        let (h, cfg) = await liveHub(["slow", "fast"])
        let slow = h.slot(cfg[0].id)!, fast = h.slot(cfg[1].id)!
        slow.foregroundHangs = true
        let fg = Task { await h.hub.handleForegroundTransition(userInitiated: true) }
        await hubSettle()
        XCTAssertEqual(fast.foregroundCount, 1, "fast gets the event while slow is still recovering")
        slow.foregroundGate?.resume(); slow.foregroundGate = nil
        await fg.value
    }

    func testStopDuringStartBuildsNoSlots() async {
        let configs = [makeConfig("a"), makeConfig("b")]
        let h = HubHarness(configs: configs, gatedSleep: true)
        let started = Task { await h.hub.start() }
        await hubSettle()                                    // both children are parked in their stagger sleep
        h.hub.stop()
        h.releaseSleeps()
        await started.value
        XCTAssertTrue(h.built.isEmpty, "a stopped hub must not connect coordinators behind the closed window")
        XCTAssertNil(h.slot(configs[0].id)); XCTAssertNil(h.slot(configs[1].id))
    }

    func testDisableBeforeTheBuildTaskRunsBuildsNothing() async {
        let configs = [makeConfig("a"), makeConfig("b", enabled: false)]
        let h = HubHarness(configs: configs)
        await h.hub.start()
        h.hub.setEnabled(configs[1].id, true)
        h.hub.setEnabled(configs[1].id, false)
        await hubSettle()
        XCTAssertNil(h.slot(configs[1].id))
        XCTAssertEqual(h.built.count, 1, "only a was ever built")
    }

    func testDeepLinkAfterStartWithOnlyTokenlessServersDoesNotHang() async {
        let h = HubHarness(configs: [makeConfig("a")], tokensFor: [])
        await h.hub.start()
        let outcome = await bounded(.seconds(2)) {
            await h.hub.handleDeepLink(SessionDeepLink(sessionId: UUID(), serverInstanceId: nil))
        }
        XCTAssertEqual(outcome, .notFound(serverName: nil))
    }

    // MARK: - Selecting what has no coordinator (review I2 / Mac I4)

    func testSelectingARowOfATokenlessServerIsRefusedWithoutDetaching() async {
        let configs = [makeConfig("a"), makeConfig("b")]
        let h = HubHarness(configs: configs, tokensFor: [configs[0].id])
        await h.hub.start()
        let a = h.slot(configs[0].id)!; a.goLive(with: [makeSession()]); await hubSettle()
        await h.hub.select(SessionRef(serverId: configs[0].id, sessionId: a.sessions[0].id))
        await h.hub.select(SessionRef(serverId: configs[1].id, sessionId: UUID()))
        XCTAssertEqual(h.hub.activeRef?.serverId, configs[0].id, "selection unchanged")
        XCTAssertEqual(a.detachActiveCount, 0, "the live session is not detached for a row that cannot attach")
        XCTAssertNotNil(h.hub.notice)
    }

    func testDisabledServerKeepsCachedRowsButTheyAreNotSelectable() async {
        let (h, cfg) = await liveHub(["a", "b"])
        let a = h.slot(cfg[0].id)!
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: a.sessions[0].id))
        let cachedB = h.hub.sections.first { $0.id == cfg[1].id }!.sessions
        h.hub.setEnabled(cfg[1].id, false); await hubSettle()
        let b = h.hub.sections.first { $0.id == cfg[1].id }!
        XCTAssertEqual(b.sessions.map(\.id), cachedB.map(\.id), "spec §7: cached list kept while disabled")
        XCTAssertTrue(h.hub.orderedRefs.allSatisfy { $0.serverId == cfg[0].id }, "keyboard navigation skips disabled sections")
        await h.hub.select(SessionRef(serverId: cfg[1].id, sessionId: cachedB[0].id))
        XCTAssertEqual(h.hub.activeRef?.serverId, cfg[0].id)
        XCTAssertEqual(a.detachActiveCount, 0)
    }

    // MARK: - Push (review I7 / Mac I6)

    func testDisablingAServerUnregistersPushBeforeTearingDown() async {
        let (h, cfg) = await liveHub(["a", "b"])
        await h.hub.syncPushRegistration(pushEnabled: true, notifyOnFinished: true)
        let b = h.slot(cfg[1].id)!
        var log: [String] = []; b.log = { log.append($0) }
        h.hub.setEnabled(cfg[1].id, false)
        XCTAssertNil(h.hub.slot(for: cfg[1].id), "gone from the hub immediately")
        await hubSettle()
        XCTAssertEqual(log, ["push:false", "teardown:b"])
    }

    func testSlotsBuiltAfterASyncReceiveTheCurrentPushSettings() async {
        let configs = [makeConfig("a"), makeConfig("b", enabled: false)]
        let h = HubHarness(configs: configs); await h.hub.start()
        await h.hub.syncPushRegistration(pushEnabled: true, notifyOnFinished: false)
        h.hub.setEnabled(configs[1].id, true); await hubSettle()
        XCTAssertEqual(h.slot(configs[1].id)!.pushSyncs.map { $0.0 }, [true])
        XCTAssertEqual(h.slot(configs[1].id)!.pushSyncs.map { $0.1 }, [false])
    }

    // MARK: - Management (Mac I5)

    func testReloadAtTheCapDisablesTheNewBookmarkWithANotice() async {
        let (h, _) = await liveHub(["a", "b"], maxEnabled: 2)
        let c = makeConfig("c")                              // paired / added: saved enabled
        h.bookmarks.add(c)
        h.hub.reloadBookmarks(); await hubSettle()
        XCTAssertFalse(h.bookmarks.loadAll().first { $0.id == c.id }!.enabled)
        XCTAssertNil(h.hub.slot(for: c.id))
        XCTAssertNotNil(h.hub.notice)
    }

    func testRebuildSlotReplacesTheCoordinator() async {
        let (h, cfg) = await liveHub(["a"])
        let old = h.slot(cfg[0].id)!
        h.hub.rebuildSlot(cfg[0].id); await hubSettle()
        XCTAssertTrue(old.tornDown)
        XCTAssertTrue(h.slot(cfg[0].id) !== old)
        XCTAssertEqual(h.slot(cfg[0].id)?.startCount, 1)
    }

    // MARK: - Focus (Mac I2)

    func testFocusCoordinatorFallsBackToTheOnlyEnabledThenFirstLiveSlot() async {
        let (h1, c1) = await liveHub(["a"])
        XCTAssertNil(h1.hub.activeRef)
        XCTAssertTrue(h1.hub.focusCoordinator === h1.slot(c1[0].id), "one enabled server: its coordinator drives the surfaces")
        let (h2, c2) = await liveHub(["a", "b"])
        h2.slot(c2[0].id)!.goOffline(); await hubSettle()
        XCTAssertTrue(h2.hub.focusCoordinator === h2.slot(c2[1].id), "several: the first LIVE one")
        await h2.hub.select(SessionRef(serverId: c2[1].id, sessionId: h2.slot(c2[1].id)!.sessions[0].id))
        XCTAssertTrue(h2.hub.focusCoordinator === h2.hub.activeCoordinator)
    }
}
