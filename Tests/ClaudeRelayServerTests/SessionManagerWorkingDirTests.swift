import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class SessionManagerWorkingDirTests: SessionManagerTestCase {
    func testWorkingDirSurfacesInListingViaActivityChange() async throws {
        let manager = makeManager()
        let info = try await manager.createSession(tokenId: "tok")
        await manager.reportActivityChange(sessionId: info.id, activity: .agentActive,
                                           agent: "claude", agentState: .working,
                                           title: nil, workingDir: "/repo/demo", revision: 1)
        let listed = await manager.listSessionsForToken(tokenId: "tok")
        XCTAssertEqual(listed.first?.workingDir, "/repo/demo")
    }

    func testReportWorkingDirNotifiesObserverWithCwd() async throws {
        let manager = makeManager()
        let token = "tok"
        let info = try await manager.createSession(tokenId: token)
        // Register AFTER create so the initial replay doesn't race our capture.
        let received = AsyncCwdBox()
        _ = await manager.addActivityObserver(tokenId: token) { _, _, _, _, _, workingDir in
            Task { await received.set(workingDir) }
        }
        await manager.reportWorkingDir(sessionId: info.id, workingDir: "/repo/live")
        try await Task.sleep(for: .milliseconds(100))
        let last = await received.value
        XCTAssertEqual(last, "/repo/live")
    }

    /// Minimal actor to capture the latest workingDir seen by the observer.
    private actor AsyncCwdBox {
        private(set) var value: String?
        func set(_ v: String?) { if v != nil { value = v } }
    }

    func testReportWorkingDirUpdatesListing() async throws {
        let manager = makeManager()
        let info = try await manager.createSession(tokenId: "tok")
        await manager.reportWorkingDir(sessionId: info.id, workingDir: "/repo/root")
        let listed = await manager.listSessionsForToken(tokenId: "tok")
        XCTAssertEqual(listed.first?.workingDir, "/repo/root")
    }

    func testWorkingDirPersistsAcrossLaterActivityWithoutCwd() async throws {
        let manager = makeManager()
        let info = try await manager.createSession(tokenId: "tok")
        await manager.reportActivityChange(sessionId: info.id, activity: .agentActive,
                                           agent: "claude", agentState: .working,
                                           title: nil, workingDir: "/repo/demo", revision: 1)
        // A later activity update carrying no cwd must not wipe the cached one.
        await manager.reportActivityChange(sessionId: info.id, activity: .agentIdle,
                                           agent: "claude", agentState: .idle,
                                           title: nil, workingDir: nil, revision: 2)
        let listed = await manager.listSessionsForToken(tokenId: "tok")
        XCTAssertEqual(listed.first?.workingDir, "/repo/demo")
    }
}
