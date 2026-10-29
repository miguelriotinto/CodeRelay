#if os(macOS)
import XCTest
import SwiftUI
@testable import CodeRelayClient

/// The sheet must keep one size through every state of a load. It used to
/// size itself to whatever rows the state had (bytes, subtitle, Cancel), so
/// the same sheet visibly grew and shrank on iPad and Mac between a switch,
/// a reconnect and the closing "Ready".
@MainActor
final class SessionLoadingSheetSizeTests: XCTestCase {
    private func size(_ p: SessionLoadingPresentation, cancel: Bool = true) -> CGSize {
        let view = SessionLoadingSheet(presentation: p, onCancel: cancel ? {} : nil)
            .sessionLoadingSheetContainer()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.nsImage?.size ?? .zero
    }

    private func make(_ phase: SessionLoadPhase?, recovering: Bool = false,
                      session: String? = nil, server: String? = nil) -> SessionLoadingPresentation {
        SessionLoadingPresentation(loadPhase: phase, isRecovering: recovering,
                                   recoveryPhase: .reconnecting, sessionName: session, serverName: server)
    }

    func testEveryStateHasTheSameSize() {
        let states: [SessionLoadingPresentation] = [
            make(.attaching),
            make(.loadingHistory(bytes: 412_000), session: "api", server: "studio"),
            make(nil, recovering: true, session: "a much longer session name that would widen the sheet",
                 server: "a server with a long name"),
            make(.loadingHistory(bytes: 9_000), session: "api").readied(),
        ]
        let sizes = states.map { size($0) }
        XCTAssertGreaterThan(sizes[0].height, 0)
        for s in sizes { XCTAssertEqual(s, sizes[0], "sizes: \(sizes)") }
    }

    func testTheFixedSizeHoldsTheTallestStateWithoutClipping() {
        // A reconnect with Cancel and a subtitle is the tallest content; its
        // natural height must fit inside the fixed frame.
        let tallest = make(nil, recovering: true, session: "api", server: "studio")
        let natural = ImageRenderer(content: SessionLoadingSheet(presentation: tallest, onCancel: {})
            .frame(width: SessionLoadingSheetLayout.fixedWidth).fixedSize(horizontal: false, vertical: true))
        natural.scale = 1
        XCTAssertLessThanOrEqual(natural.nsImage?.size.height ?? .infinity, size(tallest).height)
    }
}
#endif
