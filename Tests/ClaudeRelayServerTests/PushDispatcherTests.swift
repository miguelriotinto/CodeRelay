import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

private actor FakeSender: PushSending {
    private(set) var sent: [(token: String, body: String, collapse: String, deepLink: String, topic: String?)] = []
    var result: PushResult = .delivered
    func setResult(_ r: PushResult) { result = r }
    func send(deviceToken: String, platform: PushPlatform, topic: String?, title: String,
              body: String, deepLink: String, collapseKey: String) async -> PushResult {
        sent.append((deviceToken, body, collapseKey, deepLink, topic))
        return result
    }
    func snapshot() -> [(token: String, body: String, collapse: String, deepLink: String, topic: String?)] { sent }
}

final class PushDispatcherTests: XCTestCase {
    private func session(_ id: UUID, _ state: AgentDetectedState?, dir: String,
                         token: String = "R") -> SessionInfo {
        SessionInfo(id: id, name: nil, state: .activeAttached, tokenId: token, createdAt: Date(),
                    cols: 80, rows: 24, activity: .agentActive, agent: "claude",
                    agentState: state, title: nil, workingDir: dir)
    }

    private func reg(_ token: String, _ device: String, notifyOnFinished: Bool = false,
                     topic: String? = nil) -> PushRegistration {
        PushRegistration(platform: .apns, token: token, deviceId: device,
                         enabled: true, notifyOnFinished: notifyOnFinished, updatedAt: Date(), topic: topic)
    }

    private func makeDispatcher(sender: PushSending,
                                sessions: @escaping @Sendable (String) -> [SessionInfo],
                                tokens: @escaping @Sendable (String) -> [PushRegistration],
                                notifyOnFinished: Bool = false,
                                onDead: @escaping @Sendable (String) -> Void = { _ in },
                                clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) })
        -> PushDispatcher {
        PushDispatcher(
            sessionProvider: { sessions($0) },
            tokenProvider: { tokens($0) },
            sender: sender,
            config: PushNotifyConfig(debounceInterval: 100, notifyOnFinished: notifyOnFinished),
            onDeadToken: onDead,
            now: clock)
    }

    func testBlockedEdgeSurvivesRapidBurstToIdle() async {
        let sid = UUID()
        let sender = FakeSender()
        // Snapshot's latest state is idle (burst already ended), proving the
        // dispatcher uses the forwarded EVENT state, not a re-read snapshot.
        let d = makeDispatcher(sender: sender,
                               sessions: { _ in [self.session(sid, .idle, dir: "/repo/a")] },
                               tokens: { _ in [self.reg("dev1", "d1")] })
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .working, revision: 1))
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .blocked, revision: 2))
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .idle, revision: 3))
        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1, "the blocked edge must fire despite ending at idle")
        XCTAssertTrue(sent[0].deepLink.contains(sid.uuidString))
        XCTAssertFalse(sent[0].collapse.contains("/repo/a"), "collapse key must be hashed, not a raw path")
    }

    func testTopicIsForwardedFromRegistration() async {
        // A device's per-registration topic (its bundle id) must reach the
        // sender verbatim so an APNs provider fans out to the right iOS/macOS app.
        let sid = UUID()
        let sender = FakeSender()
        let d = makeDispatcher(sender: sender,
                               sessions: { _ in [self.session(sid, .blocked, dir: "/repo/a")] },
                               tokens: { _ in [self.reg("dev1", "d1", topic: "com.claude.relay.mac")] })
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .blocked, revision: 1))
        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].topic, "com.claude.relay.mac")
    }

    func testEnqueuePreservesOrderForBurst() async {
        // Exercises the REAL enqueue → AsyncStream → consumer path (not process
        // directly), guarding the ordering race Codex flagged: a rapid
        // working→blocked→idle burst must still fire the blocked edge exactly once.
        let sid = UUID()
        let sender = FakeSender()
        let d = makeDispatcher(sender: sender,
                               sessions: { _ in [self.session(sid, .idle, dir: "/repo/a")] },
                               tokens: { _ in [self.reg("dev1", "d1")] })
        d.enqueue(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .working, revision: 1))
        d.enqueue(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .blocked, revision: 2))
        d.enqueue(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .idle, revision: 3))
        // Poll until the stream drains (bounded).
        for _ in 0..<50 {
            if await sender.snapshot().count >= 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1, "enqueue must deliver events in order so the blocked edge survives")
    }

    func testReBlockedDoesNotFireAgain() async {
        let sid = UUID()
        let sender = FakeSender()
        let d = makeDispatcher(sender: sender,
                               sessions: { _ in [self.session(sid, .blocked, dir: "/repo/a")] },
                               tokens: { _ in [self.reg("dev1", "d1")] })
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .blocked, revision: 1))
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .blocked, revision: 2))
        let s = await sender.snapshot()
        XCTAssertEqual(s.count, 1)
    }

    func testFinishEdgeFiresWhenSiblingStillWorking() async {
        let a = UUID(), b = UUID()
        let sender = FakeSender()
        let sessions = [self.session(a, .working, dir: "/repo/a"),
                        self.session(b, .idle, dir: "/repo/a")]
        let d = makeDispatcher(sender: sender,
                               sessions: { _ in sessions },
                               tokens: { _ in [self.reg("dev1", "d1", notifyOnFinished: true)] },
                               notifyOnFinished: true)
        await d.process(ActivityEvent(sessionId: b, tokenId: "R", agentState: .working, revision: 1))
        await d.process(ActivityEvent(sessionId: b, tokenId: "R", agentState: .idle, revision: 2))
        let sibSent = await sender.snapshot()
        XCTAssertEqual(sibSent.count, 1, "a session finishing fires even if a sibling stays working")
    }

    func testFinishSuppressedWhenDeviceOptedOut() async {
        let sid = UUID()
        let sender = FakeSender()
        let d = makeDispatcher(sender: sender,
                               sessions: { _ in [self.session(sid, .idle, dir: "/repo/a")] },
                               tokens: { _ in [self.reg("dev1", "d1", notifyOnFinished: false)] },
                               notifyOnFinished: true)
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .working, revision: 1))
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .idle, revision: 2))
        let s = await sender.snapshot()
        XCTAssertTrue(s.isEmpty)
    }

    func testStaleRevisionDropped() async {
        let sid = UUID()
        let sender = FakeSender()
        let d = makeDispatcher(sender: sender,
                               sessions: { _ in [self.session(sid, .blocked, dir: "/repo/a")] },
                               tokens: { _ in [self.reg("dev1", "d1")] })
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .working, revision: 5))
        // Out-of-order older event must be ignored (can't fabricate a blocked edge).
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .blocked, revision: 3))
        let s = await sender.snapshot()
        XCTAssertTrue(s.isEmpty)
    }

    func testDeadTokenReported() async {
        let sid = UUID()
        let sender = FakeSender()
        await sender.setResult(.unregistered)
        actor Box { var dead: [String] = []; func add(_ s: String) { dead.append(s) }; func all() -> [String] { dead } }
        let box = Box()
        let d = makeDispatcher(sender: sender,
                               sessions: { _ in [self.session(sid, .blocked, dir: "/repo/a")] },
                               tokens: { _ in [self.reg("dev-dead", "d1")] },
                               onDead: { token in Task { await box.add(token) } })
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .working, revision: 1))
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .blocked, revision: 2))
        try? await Task.sleep(for: .milliseconds(50))
        let dead = await box.all()
        XCTAssertEqual(dead, ["dev-dead"])
    }

    func testOwnershipIsolation() async {
        let sid = UUID()
        let sender = FakeSender()
        // Token R owns the session; only R's devices should receive the push.
        let d = makeDispatcher(sender: sender,
                               sessions: { token in token == "R" ? [self.session(sid, .blocked, dir: "/repo/a")] : [] },
                               tokens: { token in token == "R" ? [self.reg("devR", "d1")] : [self.reg("devS", "d2")] })
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .working, revision: 1))
        await d.process(ActivityEvent(sessionId: sid, tokenId: "R", agentState: .blocked, revision: 2))
        let sent = await sender.snapshot()
        XCTAssertEqual(sent.map(\.token), ["devR"])
    }
}
