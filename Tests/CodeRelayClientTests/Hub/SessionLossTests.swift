import XCTest
import CodeRelayKit
@testable import CodeRelayClient

final class SessionLossTests: XCTestCase {
    private let a = LostSession(id: UUID(), name: "A")
    private let b = LostSession(id: UUID(), name: "B")
    private let c = LostSession(id: UUID(), name: "C")

    private func info(_ s: LostSession, _ state: SessionState, token: String = "mine") -> SessionInfo {
        SessionInfo(id: s.id, name: s.name, state: state, tokenId: token,
                    createdAt: Date(), cols: 80, rows: 24)
    }

    func testLostIncludesMissingAndTerminal() {
        let lost = SessionLossClassifier.lost(
            before: [a, b, c],
            owned: [info(a, .activeAttached), info(b, .exited)])
        XCTAssertEqual(lost, [b, c])
    }

    func testClassifyTakenVsEnded() {
        var r = SessionLossClassifier.classify(
            lost: [b, c], all: [info(b, .activeAttached, token: "other")], myTokenId: "mine")
        XCTAssertEqual(r.taken, [b])
        XCTAssertEqual(r.ended, [c])

        r = SessionLossClassifier.classify(
            lost: [b], all: [info(b, .activeAttached, token: "mine")], myTokenId: "mine")
        XCTAssertEqual(r.taken, [])
        XCTAssertEqual(r.ended, [b])

        r = SessionLossClassifier.classify(
            lost: [b], all: [info(b, .exited, token: "other")], myTokenId: "mine")
        XCTAssertEqual(r.taken, [])
        XCTAssertEqual(r.ended, [b])
    }

    func testClassifyNilAllMeansTaken() {
        let r = SessionLossClassifier.classify(lost: [a, b], all: nil, myTokenId: "mine")
        XCTAssertEqual(r.taken, [a, b])
        XCTAssertEqual(r.ended, [])
    }

    private func items(_ names: [String], server: UUID = UUID(), serverName: String = "srv") -> [SessionLossItem] {
        names.map { SessionLossItem(serverId: server, serverName: serverName,
                                    session: LostSession(id: UUID(), name: $0)) }
    }

    func testCopyOneTwoMany() {
        XCTAssertEqual(SessionLossCopy.takenTitle(count: 1), "Session Moved")
        XCTAssertEqual(SessionLossCopy.takenTitle(count: 2), "Sessions Moved")
        let s = UUID()
        func i(_ n: [String]) -> [SessionLossItem] { items(n, server: s) }
        XCTAssertEqual(SessionLossCopy.takenBody(i(["A"])), "A was attached from another device.")
        XCTAssertEqual(SessionLossCopy.takenBody(i(["A", "B"])), "A and B were attached from another device.")
        XCTAssertEqual(SessionLossCopy.takenBody(i(["A", "B", "C"])), "A, B and 1 other were attached from another device.")
        XCTAssertEqual(SessionLossCopy.takenBody(i(["A", "B", "C", "D"])), "A, B and 2 others were attached from another device.")
        XCTAssertEqual(SessionLossCopy.endedBody(i(["A"])), "A ended while you were away.")
        XCTAssertEqual(SessionLossCopy.endedBody(i(["A", "B"])), "A and B ended while you were away.")
        XCTAssertEqual(SessionLossCopy.endedBody(i(["A", "B", "C"])), "A, B and 1 other ended while you were away.")
        XCTAssertEqual(SessionLossCopy.endedBody(i(["A", "B", "C", "D"])), "A, B and 2 others ended while you were away.")
    }

    func testServerSuffixOnlyWhenMixed() {
        let s = UUID()
        XCTAssertEqual(SessionLossCopy.takenBody(items(["Renly", "Stannis"], server: s, serverName: "mac-mini")),
                       "Renly and Stannis were attached from another device.")
        let mixed = [
            SessionLossItem(serverId: UUID(), serverName: "mac-mini", session: LostSession(id: UUID(), name: "Renly")),
            SessionLossItem(serverId: UUID(), serverName: "studio", session: LostSession(id: UUID(), name: "Stannis")),
        ]
        XCTAssertEqual(SessionLossCopy.takenBody(mixed),
                       "Renly (on mac-mini) and Stannis (on studio) were attached from another device.")
    }
}
