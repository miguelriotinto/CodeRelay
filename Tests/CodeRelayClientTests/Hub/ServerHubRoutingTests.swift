import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

@MainActor
final class ServerHubRoutingTests: XCTestCase {

    private func liveHub(_ names: [String]) async -> (HubHarness, [ConnectionConfig]) {
        let configs = names.map { makeConfig($0) }
        let h = HubHarness(configs: configs)
        await h.hub.start()
        for c in configs { h.slot(c.id)!.goLive(with: [makeSession()]) }
        await hubSettle()
        return (h, configs)
    }

    // MARK: Fan-out (spec §7.3, D10)

    func testForegroundFansOutToLiveSlotsWithStagger() async {
        let (h, cfg) = await liveHub(["a", "b", "c"])
        h.slot(cfg[1].id)!.goOffline(); await hubSettle()
        h.hub.recordedSleepsReset()
        await h.hub.handleForegroundTransition(userInitiated: true)
        XCTAssertEqual(h.slot(cfg[0].id)!.foregroundCount, 1)
        XCTAssertEqual(h.slot(cfg[1].id)!.foregroundCount, 1, "offline servers get the transition too — it is how they come back")
        XCTAssertEqual(h.slot(cfg[2].id)!.foregroundCount, 1)
        XCTAssertEqual(h.hub.recordedSleeps, [.zero, .milliseconds(150), .milliseconds(300)])
    }

    func testUserRecoveryTargetsOneServerOrAll() async {
        let (h, cfg) = await liveHub(["a", "b"])
        h.hub.triggerUserRecovery(serverId: cfg[1].id)
        XCTAssertEqual(h.slot(cfg[0].id)!.userRecoveryCount, 0)
        XCTAssertEqual(h.slot(cfg[1].id)!.userRecoveryCount, 1)
        h.hub.triggerUserRecovery()
        XCTAssertEqual(h.slot(cfg[0].id)!.userRecoveryCount, 1)
        XCTAssertEqual(h.slot(cfg[1].id)!.userRecoveryCount, 2)
    }

    func testPushSyncReachesEverySlot() async {
        let (h, cfg) = await liveHub(["a", "b"])
        await h.hub.syncPushRegistration(pushEnabled: true, notifyOnFinished: false)
        XCTAssertEqual(h.slot(cfg[0].id)!.pushSyncs.count, 1)
        XCTAssertEqual(h.slot(cfg[1].id)!.pushSyncs.count, 1)
        XCTAssertEqual(h.slot(cfg[1].id)!.pushSyncs[0].0, true)
    }

    // MARK: Deep links (spec §10)

    func testInstanceIdRoutesToThatServer() async {
        let (h, cfg) = await liveHub(["a", "b"])
        let identity = ServerIdentity(id: UUID(), name: "b-relay")
        h.slot(cfg[1].id)!.serverIdentity = identity; await hubSettle()
        let target = h.slot(cfg[1].id)!.sessions[0].id
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: target, serverInstanceId: identity.id))
        XCTAssertEqual(outcome, .selected(SessionRef(serverId: cfg[1].id, sessionId: target)))
        XCTAssertEqual(h.slot(cfg[1].id)!.switchedTo, [target])
        XCTAssertEqual(h.slot(cfg[0].id)!.switchedTo, [])
    }

    func testInstanceIdOnADisabledBookmarkEnablesItWithANotice() async {
        let a = makeConfig("a"), b = makeConfig("b", enabled: false)
        var bWithIdentity = b
        let identity = ServerIdentity(id: UUID(), name: "b-relay")
        bWithIdentity.instanceId = identity.id
        let h = HubHarness(configs: [a, bWithIdentity])
        await h.hub.start()
        let target = UUID()
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: target, serverInstanceId: identity.id))
        XCTAssertEqual(outcome, .enabledAndSelected(SessionRef(serverId: b.id, sessionId: target)))
        XCTAssertTrue(h.bookmarks.loadAll()[1].enabled)
        XCTAssertEqual(h.hub.notice, "Enabled b to open this session")
        XCTAssertEqual(h.hub.activeRef, SessionRef(serverId: b.id, sessionId: target), "shown as a pending selection until b lists it")
    }

    func testUniqueSessionIdAcrossLiveSectionsRoutesWithoutServerHint() async {
        let (h, cfg) = await liveHub(["a", "b"])
        let target = h.slot(cfg[0].id)!.sessions[0].id
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: target))
        XCTAssertEqual(outcome, .selected(SessionRef(serverId: cfg[0].id, sessionId: target)))
    }

    func testUnknownSessionWithOneServerFallsBackToRemoteAttach() async {
        let (h, cfg) = await liveHub(["a"])
        let target = UUID()
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: target))
        XCTAssertEqual(outcome, .attachingRemote(serverId: cfg[0].id))
        XCTAssertEqual(h.slot(cfg[0].id)!.remoteAttaches, [target])
    }

    func testUnknownSessionWithSeveralServersIsNotFound() async {
        let (h, _) = await liveHub(["a", "b"])
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: UUID()))
        XCTAssertEqual(outcome, .notFound(serverName: nil))
        XCTAssertEqual(h.hub.notice, "Session not found on any enabled server")
    }

    func testUnknownInstanceIdNamesNothingButStillSearchesSessions() async {
        let (h, cfg) = await liveHub(["a"])
        let target = h.slot(cfg[0].id)!.sessions[0].id
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: target, serverInstanceId: UUID()))
        XCTAssertEqual(outcome, .selected(SessionRef(serverId: cfg[0].id, sessionId: target)),
                       "an instance id we have not learned yet must not block a session we can see")
    }

    func testDeepLinkBeforeStartIsQueued() async {
        let a = makeConfig("a")
        let h = HubHarness(configs: [a])
        let target = UUID()
        let early = Task { await h.hub.handleDeepLink(SessionDeepLink(sessionId: target)) }
        await Task.yield()
        await h.hub.start()
        let outcome = await early.value
        XCTAssertEqual(outcome, .attachingRemote(serverId: a.id))
    }

    // MARK: Duplicates (spec §10, §12)

    func testDuplicateInstanceIdIsFlagged() async {
        let (h, cfg) = await liveHub(["a", "b"])
        let identity = ServerIdentity(id: UUID(), name: "same")
        h.slot(cfg[0].id)!.serverIdentity = identity
        h.slot(cfg[1].id)!.serverIdentity = identity
        await hubSettle()
        XCTAssertTrue(h.hub.sections[0].isDuplicateInstance)
        XCTAssertTrue(h.hub.sections[1].isDuplicateInstance)
        let target = h.slot(cfg[0].id)!.sessions[0].id
        let outcome = await h.hub.handleDeepLink(SessionDeepLink(sessionId: target, serverInstanceId: identity.id))
        XCTAssertEqual(outcome, .selected(SessionRef(serverId: cfg[0].id, sessionId: target)), "first enabled bookmark wins")
    }
}
