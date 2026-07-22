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
