import Foundation
import Crypto
import ClaudeRelayKit

/// An activity transition forwarded from the server's global observer. Carries
/// the state AT THE EDGE (not a value to be re-looked-up), so a rapid
/// working→blocked→idle burst delivers three distinct events and no edge is lost.
public struct ActivityEvent: Sendable {
    public let sessionId: UUID
    public let tokenId: String
    public let agentState: AgentDetectedState?
    public let revision: UInt64
    public init(sessionId: UUID, tokenId: String, agentState: AgentDetectedState?, revision: UInt64) {
        self.sessionId = sessionId
        self.tokenId = tokenId
        self.agentState = agentState
        self.revision = revision
    }
}

/// Delivery policy.
public struct PushNotifyConfig: Sendable {
    public let debounceInterval: TimeInterval
    /// Server-wide gate for agent-finished notifications: a finish push fires
    /// only when this is true AND the target device opted in. Lets an admin
    /// globally disable finish pushes regardless of per-device preference.
    public let notifyOnFinished: Bool
    public init(debounceInterval: TimeInterval, notifyOnFinished: Bool) {
        self.debounceInterval = debounceInterval
        self.notifyOnFinished = notifyOnFinished
    }
}

/// Observes the activity stream and turns real per-session transition EDGES into
/// coalesced, ownership-scoped pushes.
///
/// Correctness (per plan design decision 7 + Codex review): edge detection is
/// per-session (`previousSessionState`), not aggregate rollup — so one session
/// finishing fires even when a sibling stays working. A per-session revision
/// guard drops out-of-order events. The group rollup is used only for the
/// notification body/count/deep-link and to coalesce.
public actor PushDispatcher {
    public typealias SessionProvider = @Sendable (String) async -> [SessionInfo]
    public typealias TokenProvider = @Sendable (String) async -> [PushRegistration]

    private let sessionProvider: SessionProvider
    private let tokenProvider: TokenProvider
    private let sender: PushSending
    private let config: PushNotifyConfig
    private let onDeadToken: @Sendable (String) -> Void
    private let now: @Sendable () -> Date

    // Per-session edge-detection state (capped + reaped).
    private var previousSessionState: [UUID: AgentDetectedState] = [:]
    private var lastRevision: [UUID: UInt64] = [:]
    // Per-(tokenId, groupId) debounce timestamps.
    private var lastPush: [String: Date] = [:]
    private let maxTrackedSessions = 4000
    private let maxTrackedGroups = 2000

    private nonisolated let continuation: AsyncStream<ActivityEvent>.Continuation

    public init(sessionProvider: @escaping SessionProvider,
                tokenProvider: @escaping TokenProvider,
                sender: PushSending,
                config: PushNotifyConfig,
                onDeadToken: @escaping @Sendable (String) -> Void,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.sessionProvider = sessionProvider
        self.tokenProvider = tokenProvider
        self.sender = sender
        self.config = config
        self.onDeadToken = onDeadToken
        self.now = now
        let (stream, cont) = AsyncStream<ActivityEvent>.makeStream()
        self.continuation = cont
        Task { [weak self] in
            for await event in stream { await self?.process(event) }
        }
    }

    /// Enqueue an event for ordered processing. `nonisolated` so the synchronous
    /// `@Sendable` observer closure can call it without `await`.
    ///
    /// Yields DIRECTLY into the continuation — `AsyncStream.Continuation.yield`
    /// is itself thread-safe and preserves call order, so events reach the
    /// single consumer in arrival order. (A prior `Task { yield }` per event
    /// did NOT preserve order — tasks could acquire the actor out of sequence,
    /// letting the revision guard drop a mid-burst blocked edge.)
    public nonisolated func enqueue(_ event: ActivityEvent) {
        continuation.yield(event)
    }

    /// Process one event in arrival order. `internal` so tests drive it directly.
    func process(_ event: ActivityEvent) async {
        // Ordering guard BEFORE mutating prior state: an older revision can't
        // fabricate an edge.
        if let seen = lastRevision[event.sessionId], event.revision <= seen { return }
        lastRevision[event.sessionId] = event.revision

        let previous = previousSessionState[event.sessionId]
        let current = event.agentState
        previousSessionState[event.sessionId] = current ?? .unknown
        reapIfNeeded()

        guard let edge = edgeKind(previous: previous, current: current) else { return }
        // Server-wide gate: finish pushes require the server default on too.
        if edge == .finished, !config.notifyOnFinished { return }
        await fire(edge: edge, event: event)
    }

    private enum Edge { case blocked, finished }

    private func edgeKind(previous: AgentDetectedState?, current: AgentDetectedState?) -> Edge? {
        // Blocked edge: any transition INTO blocked (but not blocked→blocked).
        if current == .blocked, previous != .blocked { return .blocked }
        // Finish edge: working → idle.
        if current == .idle, previous == .working { return .finished }
        return nil
    }

    private func fire(edge: Edge, event: ActivityEvent) async {
        let sessions = await sessionProvider(event.tokenId)
        // Resolve the triggering session's group.
        guard let triggering = sessions.first(where: { $0.id == event.sessionId }) else { return }
        let groupId = triggering.workingDir ?? "~"
        let members = sessions.filter { ($0.workingDir ?? "~") == groupId }

        // Debounce per (token, group). Only the CHECK happens here; the
        // timestamp is recorded after an actual delivery (below), so a finish
        // edge that reaches no eligible device — or a total send failure —
        // doesn't suppress a subsequent, more important blocked edge.
        let debounceKey = "\(event.tokenId)|\(groupId)"
        if let last = lastPush[debounceKey], now().timeIntervalSince(last) < config.debounceInterval {
            return
        }

        // Body/count/deep-link from the group (display name only — never the path).
        let displayTitle = Self.displayName(for: groupId)
        let attentionCount = members.filter { $0.agentState == .blocked }.count
        let body: String
        switch edge {
        case .blocked:
            body = attentionCount > 1 ? "\(attentionCount) agents blocked" : "An agent needs your input"
        case .finished:
            body = "An agent finished"
        }
        // Deep link: highest-severity member (blocked first), tie-break lowest id.
        let target = members.min { lhs, rhs in
            let ls = severity(lhs.agentState), rs = severity(rhs.agentState)
            return ls != rs ? ls > rs : lhs.id.uuidString < rhs.id.uuidString
        } ?? triggering
        let deepLink = "coderelay://session/\(target.id.uuidString)"
        let collapseKey = Self.collapseKey(for: groupId)

        let registrations = await tokenProvider(event.tokenId)
        var delivered = false
        for reg in registrations {
            guard reg.enabled else { continue }
            if edge == .finished, !reg.notifyOnFinished { continue }
            let result = await sender.send(
                deviceToken: reg.token, platform: reg.platform, topic: reg.topic,
                title: displayTitle, body: body, deepLink: deepLink, collapseKey: collapseKey)
            switch result {
            case .delivered:    delivered = true
            case .unregistered: onDeadToken(reg.token)
            case .failed:       break
            }
        }
        // Start the debounce window only once something was actually delivered.
        if delivered { lastPush[debounceKey] = now() }
    }

    private func severity(_ state: AgentDetectedState?) -> Int {
        switch state {
        case .blocked: return 4
        case .idle:    return 3
        case .working: return 2
        case .unknown, .none: return 1
        }
    }

    private func reapIfNeeded() {
        if previousSessionState.count > maxTrackedSessions {
            // Drop the sessions we haven't seen most recently (approximate: keep
            // those with the highest revisions).
            let keep = Set(lastRevision.sorted { $0.value > $1.value }
                .prefix(maxTrackedSessions / 2).map(\.key))
            previousSessionState = previousSessionState.filter { keep.contains($0.key) }
            lastRevision = lastRevision.filter { keep.contains($0.key) }
        }
        if lastPush.count > maxTrackedGroups {
            let cutoff = now().addingTimeInterval(-config.debounceInterval)
            lastPush = lastPush.filter { $0.value >= cutoff }
        }
    }

    /// Human-readable group label — leaf dir / "Other". Never a full path.
    static func displayName(for groupId: String) -> String {
        if groupId == "~" { return "Workspace" }
        return (groupId as NSString).lastPathComponent
    }

    /// Privacy-safe, bounded collapse id: hashes the group so a raw host path
    /// never reaches APNs/FCM.
    static func collapseKey(for groupId: String) -> String {
        let digest = SHA256.hash(data: Data(groupId.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "ws_" + hex.prefix(16)
    }
}
