import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

@MainActor
final class ServerHubSelectionTests: XCTestCase {

    private func liveHub(_ names: [String]) async -> (HubHarness, [ConnectionConfig]) {
        let configs = names.map { makeConfig($0) }
        let h = HubHarness(configs: configs)
        await h.hub.start()
        for c in configs { h.slot(c.id)!.goLive(with: [makeSession(), makeSession()]) }
        await hubSettle()
        return (h, configs)
    }

    func testSelectAcrossServersDetachesPreviousBeforeSwitching() async {
        let (h, cfg) = await liveHub(["a", "b"])
        var log: [String] = []
        h.slot(cfg[0].id)!.log = { log.append($0) }
        h.slot(cfg[1].id)!.log = { log.append($0) }
        let sa = h.slot(cfg[0].id)!.sessions[0].id, sb = h.slot(cfg[1].id)!.sessions[0].id

        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: sa))
        XCTAssertEqual(h.hub.activeRef, SessionRef(serverId: cfg[0].id, sessionId: sa))
        XCTAssertEqual(log, ["switch:a"], "same-server selection never detaches first")

        log.removeAll()
        await h.hub.select(SessionRef(serverId: cfg[1].id, sessionId: sb))
        XCTAssertEqual(log, ["detach:a", "switch:b"], "D9: detach on the old server strictly before the attach on the new one")
        XCTAssertEqual(h.hub.activeRef?.serverId, cfg[1].id)
        XCTAssertNil(h.slot(cfg[0].id)!.activeSessionId, "at most one coordinator holds a selection")
        XCTAssertEqual(h.state.loadActiveRef(), h.hub.activeRef, "persisted for restore (§9)")
    }

    func testSelectingTheActiveRefIsANoOp() async {
        let (h, cfg) = await liveHub(["a"])
        let s = h.slot(cfg[0].id)!.sessions[0].id
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: s))
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: s))
        XCTAssertEqual(h.slot(cfg[0].id)!.switchedTo.count, 1)
    }

    func testSelectWithinOneServerDoesNotDetachThroughTheHub() async {
        let (h, cfg) = await liveHub(["a"])
        let slot = h.slot(cfg[0].id)!
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: slot.sessions[0].id))
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: slot.sessions[1].id))
        XCTAssertEqual(slot.detachActiveCount, 0, "the coordinator's own switchToSession handles same-server detach")
        XCTAssertEqual(slot.switchedTo.count, 2)
    }

    func testHungDetachDoesNotBlockTheSwitch() async {
        let (h, cfg) = await liveHub(["a", "b"])
        h.hub.detachBudget = .milliseconds(100)
        let a = h.slot(cfg[0].id)!, b = h.slot(cfg[1].id)!
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: a.sessions[0].id))
        a.detachHangs = true
        let started = ContinuousClock.now
        await h.hub.select(SessionRef(serverId: cfg[1].id, sessionId: b.sessions[0].id))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertEqual(b.switchedTo.count, 1, "the new server was attached despite the stuck detach")
        a.detachGate?.resume()
    }

    func testSelectingOfflineRowIsAppliedWhenServerReturns() async {
        let (h, cfg) = await liveHub(["a"])
        let slot = h.slot(cfg[0].id)!
        let target = slot.sessions[1].id
        slot.goOffline(); slot.sessions = []
        await hubSettle()
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: target))
        XCTAssertEqual(slot.userRecoveryCount, 1, "selecting a cached row is the reconnect gesture (D4)")
        XCTAssertEqual(slot.switchedTo, [], "nothing attached while offline")
        XCTAssertEqual(h.hub.activeRef, SessionRef(serverId: cfg[0].id, sessionId: target), "the UI shows the selection immediately")

        slot.goLive(with: [makeSession(target)])
        await hubSettle()
        XCTAssertEqual(slot.switchedTo, [target], "pending selection applied once the list proves the session still exists")
    }

    func testPendingSelectionForAVanishedSessionIsDropped() async {
        let (h, cfg) = await liveHub(["a"])
        let slot = h.slot(cfg[0].id)!
        let target = slot.sessions[1].id
        slot.goOffline(); slot.sessions = []; await hubSettle()
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: target))
        slot.goLive(with: [makeSession()])      // server restarted: new ids
        await hubSettle()
        XCTAssertEqual(slot.switchedTo, [])
        XCTAssertNil(h.hub.activeRef, "a selection the server no longer lists is cleared (§12)")
        XCTAssertEqual(h.hub.notice, "That session has ended")
    }

    func testCreateSessionOnAnotherServerDetachesFirst() async {
        let (h, cfg) = await liveHub(["a", "b"])
        var log: [String] = []
        h.slot(cfg[0].id)!.log = { log.append($0) }; h.slot(cfg[1].id)!.log = { log.append($0) }
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: h.slot(cfg[0].id)!.sessions[0].id))
        log.removeAll()
        await h.hub.createSession(on: cfg[1].id)
        XCTAssertEqual(log, ["detach:a", "create:b"])
        XCTAssertEqual(h.hub.activeRef?.serverId, cfg[1].id)
        XCTAssertEqual(h.hub.activeRef?.sessionId, h.slot(cfg[1].id)!.activeSessionId)
    }

    func testRemoveActiveServerDetachesAndClearsActiveRef() async {
        let (h, cfg) = await liveHub(["a", "b"])
        let a = h.slot(cfg[0].id)!
        await h.hub.select(SessionRef(serverId: cfg[0].id, sessionId: a.sessions[0].id))
        await h.hub.removeServer(cfg[0].id)
        XCTAssertEqual(a.detachActiveCount, 1)
        XCTAssertTrue(a.tornDown)
        XCTAssertNil(h.hub.activeRef)
        XCTAssertNil(h.state.loadActiveRef())
        XCTAssertEqual(h.bookmarks.loadAll().map(\.id), [cfg[1].id])
        XCTAssertNil(h.tokens.tokens[cfg[0].id], "token deleted with the bookmark")
    }

    func testOrderedRefsAndNextPreviousWrapAcrossSections() async {
        let (h, cfg) = await liveHub(["a", "b"])
        let refs = h.hub.orderedRefs
        XCTAssertEqual(refs.count, 4)
        XCTAssertEqual(refs.map(\.serverId), [cfg[0].id, cfg[0].id, cfg[1].id, cfg[1].id])
        await h.hub.select(refs[1])
        await h.hub.selectNext()
        XCTAssertEqual(h.hub.activeRef, refs[2], "next crosses the section boundary")
        await h.hub.selectPrevious(); await h.hub.selectPrevious(); await h.hub.selectPrevious()
        XCTAssertEqual(h.hub.activeRef, refs[3], "previous wraps around")
    }

    func testStartRestoresThePersistedRefOnceItsServerListsIt() async {
        let a = makeConfig("a")
        let keep = UUID()
        let h = HubHarness(configs: [a])
        h.state.saveActiveRef(SessionRef(serverId: a.id, sessionId: keep))
        await h.hub.start()
        XCTAssertEqual(h.hub.activeRef, SessionRef(serverId: a.id, sessionId: keep), "shown immediately as cached selection")
        h.slot(a.id)!.goLive(with: [makeSession(keep)])
        await hubSettle()
        XCTAssertEqual(h.slot(a.id)!.switchedTo, [keep])
    }

    func testStartDropsAPersistedRefWhoseServerIsDisabled() async {
        let a = makeConfig("a", enabled: false)
        let h = HubHarness(configs: [a])
        h.state.saveActiveRef(SessionRef(serverId: a.id, sessionId: UUID()))
        await h.hub.start()
        XCTAssertNil(h.hub.activeRef)
    }
}
