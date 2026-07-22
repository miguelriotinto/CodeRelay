import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

/// Activity, steal, and rename observer behavior plus the periodic stale-observer purge.
final class SessionObserverTests: SessionManagerTestCase {

    // MARK: - Activity Observers

    func testActivityObserverReceivesChanges() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        var received: [ActivityState] = []
        var receivedAgents: [String?] = []
        let expectation = XCTestExpectation(description: "activity callback")
        expectation.expectedFulfillmentCount = 2
        let observerId = await manager.addActivityObserver(tokenId: tokenInfo.id) { sessionId, activity, agent, _, _, _ in
            XCTAssertEqual(sessionId, session.id)
            received.append(activity)
            receivedAgents.append(agent)
            expectation.fulfill()
        }

        await manager.reportActivityChange(sessionId: session.id, activity: .agentActive, agent: "claude")
        await fulfillment(of: [expectation], timeout: 1.0)
        // First callback is initial state push (.active, nil agent), second is explicit change.
        XCTAssertEqual(received, [.active, .agentActive])
        XCTAssertEqual(receivedAgents, [nil, "claude"])
        await manager.removeActivityObserver(id: observerId)
    }

    func testActivityObserverOnlyReceivesOwnToken() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = makeManager()

        let sessionA = try await manager.createSession(tokenId: tokenA.id)
        let sessionB = try await manager.createSession(tokenId: tokenB.id)

        var receivedSessionIds: [UUID] = []
        let expectation = XCTestExpectation(description: "only token A")
        expectation.expectedFulfillmentCount = 2
        let observerId = await manager.addActivityObserver(tokenId: tokenA.id) { sessionId, _, _, _, _, _ in
            receivedSessionIds.append(sessionId)
            expectation.fulfill()
        }

        await manager.reportActivityChange(sessionId: sessionB.id, activity: .agentActive, agent: "claude")
        await manager.reportActivityChange(sessionId: sessionA.id, activity: .idle)

        await fulfillment(of: [expectation], timeout: 1.0)
        // Initial push for sessionA + explicit change for sessionA (not sessionB)
        XCTAssertEqual(receivedSessionIds, [sessionA.id, sessionA.id])
        await manager.removeActivityObserver(id: observerId)
    }

    func testRemoveActivityObserverStopsCallbacks() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        var callCount = 0
        let observerId = await manager.addActivityObserver(tokenId: tokenInfo.id) { _, _, _, _, _, _ in
            callCount += 1
        }

        // callCount is 1 from initial state push on registration
        await manager.reportActivityChange(sessionId: session.id, activity: .agentActive, agent: "claude")
        // callCount is now 2
        await manager.removeActivityObserver(id: observerId)
        await manager.reportActivityChange(sessionId: session.id, activity: .idle)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(callCount, 2, "Should not receive callbacks after removal")
    }

    // MARK: - Steal Observers

    func testStealObserverFiresOnReattach() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        let expectation = XCTestExpectation(description: "steal callback")
        let observerId = await manager.addStealObserver(tokenId: tokenInfo.id) { sessionId in
            XCTAssertEqual(sessionId, session.id)
            expectation.fulfill()
        }

        // Session is already activeAttached from createSession.
        // Re-attaching should fire the steal observer.
        _ = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id)

        await fulfillment(of: [expectation], timeout: 1.0)
        await manager.removeStealObserver(id: observerId)
    }

    func testStealObserverExcludesSelf() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        var callCount = 0
        let observerId = await manager.addStealObserver(tokenId: tokenInfo.id) { _ in
            callCount += 1
        }

        // Exclude our own observer — should NOT fire.
        _ = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id, excludeObserver: observerId)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(callCount, 0, "Excluded observer should not fire")
        await manager.removeStealObserver(id: observerId)
    }

    func testStealObserverDoesNotFireOnResume() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        // Detach first, then resume (not a re-attach from activeAttached)
        try await manager.detachSession(id: session.id)

        var callCount = 0
        let observerId = await manager.addStealObserver(tokenId: tokenInfo.id) { _ in
            callCount += 1
        }

        // Resume from detached state — this is not a steal.
        _ = try await manager.resumeSession(id: session.id, tokenId: tokenInfo.id)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(callCount, 0, "Steal should not fire for resume from detached state")
        await manager.removeStealObserver(id: observerId)
    }

    /// Cross-device displacement via resume. When a session is currently
    /// `.activeAttached` (held by another connection sharing the same token)
    /// and a second connection resumes it, the original holder MUST receive a
    /// steal notification — otherwise it keeps showing a session it no longer
    /// owns. This mirrors `attachSession`'s behaviour. The resuming connection
    /// excludes its own observer so it doesn't get told it stole from itself.
    func testStealObserverFiresOnResumeFromActiveAttached() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        // createSession leaves the session in .activeAttached.
        let session = try await manager.createSession(tokenId: tokenInfo.id)

        let displaced = XCTestExpectation(description: "displaced observer fires")
        let displacedId = await manager.addStealObserver(tokenId: tokenInfo.id) { sessionId in
            XCTAssertEqual(sessionId, session.id)
            displaced.fulfill()
        }

        var resumerCalls = 0
        let resumerId = await manager.addStealObserver(tokenId: tokenInfo.id) { _ in
            resumerCalls += 1
        }

        // Resume from .activeAttached, excluding the resuming connection's own
        // observer — the displaced holder must still be notified.
        _ = try await manager.resumeSession(
            id: session.id,
            tokenId: tokenInfo.id,
            excludeObserver: resumerId
        )

        await fulfillment(of: [displaced], timeout: 1.0)
        XCTAssertEqual(resumerCalls, 0, "Resuming connection must not be told it stole from itself")
        await manager.removeStealObserver(id: displacedId)
        await manager.removeStealObserver(id: resumerId)
    }

    func testStealObserverMultipleObserversOnlyNonExcludedFire() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        var observer1Calls = 0
        var observer2Calls = 0
        let exp2 = XCTestExpectation(description: "observer2 fires")

        let id1 = await manager.addStealObserver(tokenId: tokenInfo.id) { _ in
            observer1Calls += 1
        }
        _ = await manager.addStealObserver(tokenId: tokenInfo.id) { _ in
            observer2Calls += 1
            exp2.fulfill()
        }

        // Exclude observer 1 — only observer 2 should fire
        _ = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id, excludeObserver: id1)
        await fulfillment(of: [exp2], timeout: 1.0)
        XCTAssertEqual(observer1Calls, 0, "Excluded observer should not fire")
        XCTAssertEqual(observer2Calls, 1, "Non-excluded observer should fire once")
    }

    // MARK: - C-03 Revision Ordering

    /// A stale activity update must not overwrite a newer one. Two tasks that
    /// race to `reportActivityChange` can interleave across isolation
    /// boundaries; the revision counter serializes them on the manager side.
    func testStaleActivityUpdatesAreDropped() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        // Apply a high revision first, then a lower one. The lower one must
        // be dropped.
        await manager.reportActivityChange(
            sessionId: session.id, activity: .agentActive, agent: "claude", revision: 5)
        let afterHigh = await manager.listSessionsForToken(tokenId: tokenInfo.id)
            .first(where: { $0.id == session.id })
        XCTAssertEqual(afterHigh?.activity, .agentActive)
        XCTAssertEqual(afterHigh?.agent, "claude")

        await manager.reportActivityChange(
            sessionId: session.id, activity: .idle, agent: nil, revision: 3)
        let afterLow = await manager.listSessionsForToken(tokenId: tokenInfo.id)
            .first(where: { $0.id == session.id })
        XCTAssertEqual(afterLow?.activity, .agentActive,
            "Lower-revision update must not rewind cached activity state")
        XCTAssertEqual(afterLow?.agent, "claude")

        // A strictly higher revision must apply.
        await manager.reportActivityChange(
            sessionId: session.id, activity: .idle, agent: nil, revision: 9)
        let afterNewer = await manager.listSessionsForToken(tokenId: tokenInfo.id)
            .first(where: { $0.id == session.id })
        XCTAssertEqual(afterNewer?.activity, .idle)
        XCTAssertNil(afterNewer?.agent)
    }

    // MARK: - Periodic Observer Cleanup

    func testGlobalActivityObserverReceivesTokenIdAndRevision() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()
        let session = try await manager.createSession(tokenId: tokenInfo.id)

        actor Capture {
            var events: [(UUID, String, AgentDetectedState?, UInt64)] = []
            func add(_ e: (UUID, String, AgentDetectedState?, UInt64)) { events.append(e) }
            func all() -> [(UUID, String, AgentDetectedState?, UInt64)] { events }
        }
        let capture = Capture()
        let id = await manager.addGlobalActivityObserver { sid, tid, _, agentState, revision in
            Task { await capture.add((sid, tid, agentState, revision)) }
        }

        await manager.reportActivityChange(sessionId: session.id, activity: .agentActive,
                                           agent: "claude", agentState: .working, revision: 7)
        try await Task.sleep(for: .milliseconds(50))
        let events = await capture.all()
        XCTAssertTrue(events.contains { $0.0 == session.id && $0.1 == tokenInfo.id
            && $0.2 == .working && $0.3 == 7 })

        await manager.removeGlobalActivityObserver(id: id)
        await manager.reportActivityChange(sessionId: session.id, activity: .agentIdle,
                                           agent: "claude", agentState: .idle, revision: 8)
        try await Task.sleep(for: .milliseconds(50))
        let after = await capture.all()
        XCTAssertFalse(after.contains { $0.3 == 8 }, "removed observer must stop receiving")
    }

    func testPurgeStaleObserversRemovesOldEntries() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        _ = await manager.addActivityObserver(tokenId: tokenInfo.id) { _, _, _, _, _, _ in }
        _ = await manager.addStealObserver(tokenId: tokenInfo.id) { _ in }
        _ = await manager.addRenameObserver(tokenId: tokenInfo.id) { _, _ in }

        let beforeCount = await manager._testOnly_observerCount
        XCTAssertEqual(beforeCount, 3, "Should have 3 observers registered")

        // Purge with zero-second cutoff evicts everything because Date() is strictly
        // greater than any timestamp we just recorded.
        await manager.purgeStaleObservers(olderThan: 0)

        let afterCount = await manager._testOnly_observerCount
        XCTAssertEqual(afterCount, 0, "All observers should have been purged with 0s cutoff")
    }
}
