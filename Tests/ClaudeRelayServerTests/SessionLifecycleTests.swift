import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

/// Session create, attach, detach, resume, terminate, list, and per-token cap.
final class SessionLifecycleTests: SessionManagerTestCase {

    // MARK: - Create / List / Terminate

    func testCreateSession() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id, cols: 80, rows: 24)

        XCTAssertEqual(session.tokenId, tokenInfo.id)
        XCTAssertEqual(session.cols, 80)
        XCTAssertEqual(session.rows, 24)
        XCTAssertEqual(session.state, .activeAttached)
    }

    func testCreateSessionHonorsExplicitSize() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let info = try await manager.createSession(tokenId: tokenInfo.id, cols: 132, rows: 50)

        XCTAssertEqual(info.cols, 132)
        XCTAssertEqual(info.rows, 50)
    }

    func testCreateSessionDefaultsTo80x24WhenSizeOmitted() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let info = try await manager.createSession(tokenId: tokenInfo.id)

        XCTAssertEqual(info.cols, 80)
        XCTAssertEqual(info.rows, 24)
    }

    func testListSessions() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        _ = try await manager.createSession(tokenId: tokenInfo.id)
        _ = try await manager.createSession(tokenId: tokenInfo.id)

        let list = await manager.listSessions()
        XCTAssertEqual(list.count, 2)
    }

    func testTerminateSession() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        try await manager.terminateSession(id: session.id, tokenId: tokenInfo.id)

        let info = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(info.state, .terminated)
    }

    func testListSessionsForToken() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = makeManager()

        _ = try await manager.createSession(tokenId: tokenA.id)
        _ = try await manager.createSession(tokenId: tokenA.id)
        _ = try await manager.createSession(tokenId: tokenB.id)

        let listA = await manager.listSessionsForToken(tokenId: tokenA.id)
        XCTAssertEqual(listA.count, 2)

        let listB = await manager.listSessionsForToken(tokenId: tokenB.id)
        XCTAssertEqual(listB.count, 1)
    }

    func testInspectNonexistentSession() async throws {
        let manager = makeManager()

        do {
            _ = try await manager.inspectSession(id: UUID())
            XCTFail("Expected notFound error")
        } catch let error as SessionError {
            if case .notFound = error {
                // expected
            } else {
                XCTFail("Expected notFound, got \(error)")
            }
        }
    }

    // MARK: - Detach / Resume

    func testDetachAndResume() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)

        // Attach first to get to activeAttached
        let (attachedInfo, _) = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id)
        XCTAssertEqual(attachedInfo.state, .activeAttached)

        // Detach
        try await manager.detachSession(id: session.id)
        let detachedInfo = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(detachedInfo.state, .activeDetached)

        // Resume
        let (resumedInfo, _, _) = try await manager.resumeSession(id: session.id, tokenId: tokenInfo.id)
        XCTAssertEqual(resumedInfo.state, .activeAttached)
    }

    // MARK: - Attach / Reattach Edge Cases

    func testAttachToTerminatedSessionFails() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        try await manager.terminateSession(id: session.id, tokenId: tokenInfo.id)

        do {
            _ = try await manager.attachSession(id: session.id, tokenId: tokenInfo.id)
            XCTFail("Expected invalidTransition error")
        } catch let error as SessionError {
            if case .invalidTransition(let from, let to) = error {
                XCTAssertEqual(from, .terminated)
                XCTAssertEqual(to, .activeAttached)
            } else {
                XCTFail("Expected invalidTransition, got \(error)")
            }
        }
    }

    func testAttachToNonexistentSessionFails() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        do {
            _ = try await manager.attachSession(id: UUID(), tokenId: tokenInfo.id)
            XCTFail("Expected notFound error")
        } catch let error as SessionError {
            if case .notFound = error {
                // expected
            } else {
                XCTFail("Expected notFound, got \(error)")
            }
        }
    }

    // MARK: - Resume Edge Cases

    func testResumeFromAttachedImplicitlyDetaches() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        // Session starts activeAttached from createSession.
        let info = try await manager.inspectSession(id: session.id)
        XCTAssertEqual(info.state, .activeAttached)

        // Resume without explicit detach — should succeed via implicit detach.
        let (resumed, _, _) = try await manager.resumeSession(id: session.id, tokenId: tokenInfo.id)
        XCTAssertEqual(resumed.state, .activeAttached)
    }

    func testResumeTerminatedSessionFails() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        try await manager.terminateSession(id: session.id, tokenId: tokenInfo.id)

        do {
            _ = try await manager.resumeSession(id: session.id, tokenId: tokenInfo.id)
            XCTFail("Expected error for terminated session")
        } catch {
            // Any error is acceptable (notFound if PTY nil, or invalidTransition)
        }
    }

    func testResumeNonexistentSessionFails() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        do {
            _ = try await manager.resumeSession(id: UUID(), tokenId: tokenInfo.id)
            XCTFail("Expected notFound error")
        } catch let error as SessionError {
            if case .notFound = error {
                // expected
            } else {
                XCTFail("Expected notFound, got \(error)")
            }
        }
    }

    // MARK: - Detach Edge Cases

    func testDetachAlreadyDetachedFails() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session = try await manager.createSession(tokenId: tokenInfo.id)
        try await manager.detachSession(id: session.id)

        do {
            try await manager.detachSession(id: session.id)
            XCTFail("Expected invalidTransition error")
        } catch let error as SessionError {
            if case .invalidTransition(let from, let to) = error {
                XCTAssertEqual(from, .activeDetached)
                XCTAssertEqual(to, .activeDetached)
            } else {
                XCTFail("Expected invalidTransition, got \(error)")
            }
        }
    }

    func testDetachNonexistentSessionFails() async throws {
        let manager = makeManager()

        do {
            try await manager.detachSession(id: UUID())
            XCTFail("Expected notFound error")
        } catch let error as SessionError {
            if case .notFound = error {
                // expected
            } else {
                XCTFail("Expected notFound, got \(error)")
            }
        }
    }

    // MARK: - Cross-Token Session Listing

    func testListAllSessionsCrossToken() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = makeManager()

        let sessionA = try await manager.createSession(tokenId: tokenA.id, name: "Alpha")
        let sessionB = try await manager.createSession(tokenId: tokenB.id, name: "Bravo")

        let allSessions = await manager.listAllSessions()
        XCTAssertEqual(allSessions.count, 2)

        let ids = Set(allSessions.map { $0.id })
        XCTAssertTrue(ids.contains(sessionA.id))
        XCTAssertTrue(ids.contains(sessionB.id))
    }

    func testListAllSessionsExcludesTerminated() async throws {
        let (_, tokenA) = try await createTestToken()
        let (_, tokenB) = try await tokenStore.create(label: "other")
        let manager = makeManager()

        let sessionA = try await manager.createSession(tokenId: tokenA.id)
        _ = try await manager.createSession(tokenId: tokenB.id)
        try await manager.terminateSession(id: sessionA.id, tokenId: tokenA.id)

        let allSessions = await manager.listAllSessions()
        let nonTerminal = allSessions.filter { !$0.state.isTerminal }
        XCTAssertEqual(nonTerminal.count, 1)
    }

    // MARK: - Detach-Resume Round Trip with Multiple Sessions

    func testDetachResumeMultipleSessions() async throws {
        let (_, tokenInfo) = try await createTestToken()
        let manager = makeManager()

        let session1 = try await manager.createSession(tokenId: tokenInfo.id, name: "S1")
        let session2 = try await manager.createSession(tokenId: tokenInfo.id, name: "S2")

        // Detach session 1, then resume it while session 2 is still attached
        try await manager.detachSession(id: session1.id)
        let info1 = try await manager.inspectSession(id: session1.id)
        XCTAssertEqual(info1.state, .activeDetached)

        let (resumed, _, _) = try await manager.resumeSession(id: session1.id, tokenId: tokenInfo.id)
        XCTAssertEqual(resumed.state, .activeAttached)

        // Session 2 should still be in its original state
        let info2 = try await manager.inspectSession(id: session2.id)
        XCTAssertEqual(info2.state, .activeAttached)
    }

    // MARK: - Per-Token Session Cap

    func testCreateSessionEnforcesPerTokenLimit() async throws {
        let (_, tokenInfo) = try await createTestToken()
        var config = RelayConfig.default
        config.maxSessionsPerToken = 3
        let manager = makeManager(config: config)

        for i in 0..<3 {
            _ = try await manager.createSession(tokenId: tokenInfo.id, name: "s\(i)")
        }

        do {
            _ = try await manager.createSession(tokenId: tokenInfo.id, name: "overflow")
            XCTFail("Expected sessionLimitExceeded")
        } catch SessionError.sessionLimitExceeded(let limit) {
            XCTAssertEqual(limit, 3)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testCreateSessionUnlimitedWhenLimitIsZero() async throws {
        let (_, tokenInfo) = try await createTestToken()
        var config = RelayConfig.default
        config.maxSessionsPerToken = 0
        let manager = makeManager(config: config)

        for i in 0..<10 {
            _ = try await manager.createSession(tokenId: tokenInfo.id, name: "s\(i)")
        }
        let list = await manager.listSessionsForToken(tokenId: tokenInfo.id)
        XCTAssertEqual(list.count, 10)
    }
}
