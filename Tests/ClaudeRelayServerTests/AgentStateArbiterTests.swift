import XCTest
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class AgentStateArbiterTests: XCTestCase {

    /// Build a monitor already "inside an agent" so screen detection applies.
    /// `entryDate` stamps agent entry with a CONTROLLED clock so the 3s startup
    /// grace is computed against the same fake timeline the test passes to
    /// `updateScreenDetection`. Using the 2001 reference epoch (internal value 0.0)
    /// keeps arithmetic at small magnitude so floating-point ops remain exact.
    private func makeAgentMonitor(
        entryDate: Date,
        onChange: @escaping @Sendable (AgentDetectedState?) -> Void
    ) -> SessionActivityMonitor {
        let monitor = SessionActivityMonitor(
            silenceThreshold: 10, agentSilenceThreshold: 10,
            onChange: { _, _, agentState, _, _ in onChange(agentState) }
        )
        monitor.updateForegroundProcess(agent: .claude, now: entryDate)   // enter agent
        return monitor
    }

    private func detection(_ state: AgentDetectedState, visibleIdle: Bool = false,
                           visibleBlocker: Bool = false, visibleWorking: Bool = false,
                           skip: Bool = false) -> AgentDetection {
        AgentDetection(state: state, skipStateUpdate: skip,
                       visibleIdle: visibleIdle, visibleBlocker: visibleBlocker, visibleWorking: visibleWorking)
    }

    func testBlockedPublishesImmediately() {
        var last: AgentDetectedState?
        let entry = Date(timeIntervalSinceReferenceDate: 0)
        let monitor = makeAgentMonitor(entryDate: entry) { last = $0 }
        // Past the 3s startup grace.
        monitor.updateScreenDetection(detection(.blocked, visibleBlocker: true), now: entry.addingTimeInterval(5))
        XCTAssertEqual(last, .blocked)
    }

    func testSkipStateUpdateFreezesState() {
        var updates: [AgentDetectedState?] = []
        let entry = Date(timeIntervalSinceReferenceDate: 0)
        let monitor = makeAgentMonitor(entryDate: entry) { updates.append($0) }
        let base = entry.addingTimeInterval(5)
        monitor.updateScreenDetection(detection(.working, visibleWorking: true), now: base)
        updates.removeAll()
        // A transcript-viewer overlay must not change the published state.
        monitor.updateScreenDetection(detection(.unknown, skip: true), now: base.addingTimeInterval(1))
        XCTAssertTrue(updates.isEmpty, "skipStateUpdate must not emit a new agentState")
    }

    func testWorkingToPlainIdleIsHeldThenConfirmed() {
        var last: AgentDetectedState?
        let entry = Date(timeIntervalSinceReferenceDate: 0)
        let monitor = makeAgentMonitor(entryDate: entry) { last = $0 }
        let t0 = entry.addingTimeInterval(5)
        monitor.updateScreenDetection(detection(.working, visibleWorking: true), now: t0)
        last = nil
        // First plain-idle: held (no publish).
        monitor.updateScreenDetection(detection(.idle), now: t0.addingTimeInterval(0.1))
        XCTAssertNil(last, "first Working→plain-idle is held")
        // After the 700ms cap, idle is published.
        monitor.updateScreenDetection(detection(.idle), now: t0.addingTimeInterval(0.8))
        XCTAssertEqual(last, .idle)
    }

    func testVisibleIdleBypassesHold() {
        var last: AgentDetectedState?
        let entry = Date(timeIntervalSinceReferenceDate: 0)
        let monitor = makeAgentMonitor(entryDate: entry) { last = $0 }
        let t0 = entry.addingTimeInterval(5)
        monitor.updateScreenDetection(detection(.working, visibleWorking: true), now: t0)
        last = nil
        // A visible idle prompt box is authoritative — publish immediately.
        monitor.updateScreenDetection(detection(.idle, visibleIdle: true), now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(last, .idle)
    }

    // MARK: - F6 hook-authored state authority

    func testHookStatePublishesImmediately() {
        var last: AgentDetectedState?
        let entry = Date(timeIntervalSinceReferenceDate: 0)
        let monitor = makeAgentMonitor(entryDate: entry) { last = $0 }
        monitor.applyHookState(.blocked, now: entry.addingTimeInterval(1))
        XCTAssertEqual(last, .blocked, "hook state publishes without waiting for screen anti-flap")
    }

    func testFreshHookStateOverridesScreenDetection() {
        var last: AgentDetectedState?
        let entry = Date(timeIntervalSinceReferenceDate: 0)
        let monitor = makeAgentMonitor(entryDate: entry) { last = $0 }
        let t0 = entry.addingTimeInterval(5)
        monitor.applyHookState(.working, now: t0)
        last = nil
        // Screen says idle 1s later, but the hook (working) is still fresh → ignored.
        monitor.updateScreenDetection(detection(.idle, visibleIdle: true), now: t0.addingTimeInterval(1))
        XCTAssertNil(last, "screen detection must not override a fresh hook state")
    }

    func testScreenDetectionResumesWhenHookStateGoesStale() {
        var last: AgentDetectedState?
        let entry = Date(timeIntervalSinceReferenceDate: 0)
        let monitor = makeAgentMonitor(entryDate: entry) { last = $0 }
        let t0 = entry.addingTimeInterval(5)
        monitor.applyHookState(.working, now: t0)
        last = nil
        // 11s later (> 10s TTL) the hook is stale → screen detection wins again.
        monitor.updateScreenDetection(detection(.idle, visibleIdle: true), now: t0.addingTimeInterval(11))
        XCTAssertEqual(last, .idle, "stale hook state must let screen detection resume")
    }

    func testHookStateIgnoredWhenNoAgentActive() {
        var last: AgentDetectedState?
        // A monitor with no agent entered — a stray hook must not fabricate one.
        let monitor = SessionActivityMonitor(
            silenceThreshold: 10, agentSilenceThreshold: 10,
            onChange: { _, _, agentState, _, _ in last = agentState }
        )
        monitor.applyHookState(.blocked, now: Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertNil(last, "hook state for a session with no active agent is ignored")
    }
}
