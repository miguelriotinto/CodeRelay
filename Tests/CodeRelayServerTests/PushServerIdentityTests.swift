import XCTest
@testable import CodeRelayServer
@testable import CodeRelayKit

/// Multi-server spec §6.3/§10: pushes from different relays must not collapse
/// into each other, and a tap must know which relay to open.
final class PushServerIdentityTests: XCTestCase {

    private actor Recorder: PushSending {
        private(set) var sent: [(deepLink: String, collapseKey: String, serverId: String)] = []
        func send(deviceToken: String, platform: PushPlatform, topic: String?, title: String,
                  body: String, deepLink: String, collapseKey: String, serverId: String) async -> PushResult {
            sent.append((deepLink, collapseKey, serverId))
            return .delivered
        }
        func snapshot() -> [(deepLink: String, collapseKey: String, serverId: String)] { sent }
    }

    private let serverA = "0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D"
    private let serverB = "7A6B5C4D-3E2F-4A1B-8C9D-0E1F2A3B4C5D"

    private func session(_ id: UUID, dir: String?) -> SessionInfo {
        SessionInfo(id: id, name: nil, state: .activeAttached, tokenId: "R", createdAt: Date(),
                    cols: 80, rows: 24, activity: .agentActive, agent: "claude",
                    agentState: .blocked, title: nil, workingDir: dir)
    }

    private func dispatcher(serverId: String, sender: Recorder, sessions: [SessionInfo]) -> PushDispatcher {
        PushDispatcher(
            sessionProvider: { _ in sessions },
            tokenProvider: { _ in [PushRegistration(platform: .apns, token: "dev", deviceId: "d1", enabled: true,
                                                    notifyOnFinished: false, updatedAt: Date(), topic: nil)] },
            sender: sender,
            config: PushNotifyConfig(debounceInterval: 100, notifyOnFinished: false),
            serverId: serverId,
            onDeadToken: { _ in },
            now: { Date(timeIntervalSince1970: 0) })
    }

    func testCollapseKeyDiffersAcrossServersAndIsStableWithinOne() {
        let a1 = PushDispatcher.collapseKey(for: "/Users/alice/proj", serverId: serverA)
        let a2 = PushDispatcher.collapseKey(for: "/Users/alice/proj", serverId: serverA)
        let b = PushDispatcher.collapseKey(for: "/Users/alice/proj", serverId: serverB)
        XCTAssertEqual(a1, a2)
        XCTAssertNotEqual(a1, b, "same checkout path on two hosts must not collapse together")
        XCTAssertTrue(a1.hasPrefix("ws_"))
        XCTAssertEqual(a1.count, 3 + 16)
        XCTAssertFalse(a1.contains("alice"), "collapse key stays a hash")
    }

    func testDeepLinkCarriesTheServerQuery() async {
        let sid = UUID()
        let sender = Recorder()
        let d = dispatcher(serverId: serverA, sender: sender, sessions: [session(sid, dir: "/repo/a")])
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .blocked, revision: 1))
        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].deepLink, "coderelay://session/\(sid.uuidString)?server=\(serverA)")
        XCTAssertEqual(sent[0].serverId, serverA)
        XCTAssertEqual(sent[0].collapseKey, PushDispatcher.collapseKey(for: "/repo/a", serverId: serverA))
    }

    func testNilWorkingDirStillGetsServerScopedLinkAndKey() async {
        let sid = UUID()
        let sender = Recorder()
        let d = dispatcher(serverId: serverB, sender: sender, sessions: [session(sid, dir: nil)])
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .blocked, revision: 1))
        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].deepLink.hasSuffix("?server=\(serverB)"))
        XCTAssertEqual(sent[0].collapseKey, PushDispatcher.collapseKey(for: "~", serverId: serverB))
    }
}
